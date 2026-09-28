"""Мини-парсер Lua-таблиц из SavedVariables WoW и запись Sagas.lua.

WoW сохраняет SavedVariables как Lua-код вида:
    HordeChronicleDB = {
        ["kills"] = {
            {
                ["victim"] = { ["name"] = "Ламберт", ... },
                ...
            }, -- [1]
        },
    }
Поддерживается ровно то, что пишет игра: таблицы, строки с экранированием, числа, true/false/nil,
ключи ["строка"], [число] и голые имена, позиционные значения, комментарии «--».
"""
from __future__ import annotations

import re

_NUM = re.compile(r"-?(?:0[xX][0-9a-fA-F]+|\d+\.?\d*(?:[eE][-+]?\d+)?|\.\d+(?:[eE][-+]?\d+)?)")
_NAME = re.compile(r"[A-Za-z_][A-Za-z0-9_]*")
_ESC = {"n": "\n", "t": "\t", "r": "\r", "\\": "\\", '"': '"', "'": "'", "a": "\a", "b": "\b", "f": "\f", "v": "\v", "\n": "\n"}


class LuaParseError(ValueError):
    pass


class _Parser:
    def __init__(self, text: str) -> None:
        self.s = text
        self.i = 0

    def error(self, msg: str) -> LuaParseError:
        line = self.s.count("\n", 0, self.i) + 1
        return LuaParseError(f"{msg} (строка {line})")

    def skip(self) -> None:
        s = self.s
        while self.i < len(s):
            c = s[self.i]
            if c in " \t\r\n,;":
                self.i += 1
            elif s.startswith("--", self.i):
                if s.startswith("--[[", self.i):
                    end = s.find("]]", self.i)
                    self.i = len(s) if end < 0 else end + 2
                else:
                    end = s.find("\n", self.i)
                    self.i = len(s) if end < 0 else end + 1
            else:
                break

    def value(self):
        self.skip()
        s, i = self.s, self.i
        if i >= len(s):
            raise self.error("неожиданный конец файла")
        c = s[i]
        if c == "{":
            return self.table()
        if c in "\"'":
            return self.string()
        if s.startswith("true", i):
            self.i += 4
            return True
        if s.startswith("false", i):
            self.i += 5
            return False
        if s.startswith("nil", i):
            self.i += 3
            return None
        m = _NUM.match(s, i)
        if m:
            self.i = m.end()
            t = m.group(0)
            if t.lower().startswith(("0x", "-0x")):
                return int(t, 16)
            return float(t) if any(ch in t for ch in ".eE") else int(t)
        raise self.error(f"непонятное значение: {s[i:i + 20]!r}")

    def string(self) -> str:
        q = self.s[self.i]
        self.i += 1
        out: list[str] = []
        raw = bytearray()

        def flush_raw():
            if raw:
                out.append(raw.decode("utf-8", errors="replace"))
                raw.clear()

        s = self.s
        while self.i < len(s):
            c = s[self.i]
            if c == q:
                self.i += 1
                flush_raw()
                return "".join(out)
            if c == "\\":
                nxt = s[self.i + 1]
                if nxt.isdigit():
                    m = re.match(r"\d{1,3}", s[self.i + 1:])
                    raw.append(int(m.group(0)))   # \ddd — байт UTF-8
                    self.i += 1 + len(m.group(0))
                    continue
                flush_raw()
                out.append(_ESC.get(nxt, nxt))
                self.i += 2
                continue
            flush_raw()
            out.append(c)
            self.i += 1
        raise self.error("незакрытая строка")

    def table(self):
        self.i += 1  # {
        arr: list = []
        obj: dict = {}
        while True:
            self.skip()
            if self.i >= len(self.s):
                raise self.error("незакрытая таблица")
            if self.s[self.i] == "}":
                self.i += 1
                break
            if self.s[self.i] == "[":
                self.i += 1
                key = self.value()
                self.skip()
                if self.s[self.i] != "]":
                    raise self.error("ожидалась ]")
                self.i += 1
                self.expect_eq()
                obj[key] = self.value()
                continue
            m = _NAME.match(self.s, self.i)
            if m and self.s[m.end():].lstrip().startswith("=") and not self.s[m.end():].lstrip().startswith("=="):
                self.i = m.end()
                self.expect_eq()
                obj[m.group(0)] = self.value()
                continue
            arr.append(self.value())
        if obj and not arr and all(isinstance(k, int) for k in obj):
            keys = sorted(obj)
            if keys == list(range(1, len(keys) + 1)):
                return [obj[k] for k in keys]
        if arr and not obj:
            return arr
        if arr:
            for n, v in enumerate(arr, 1):
                obj.setdefault(n, v)
        return obj

    def expect_eq(self) -> None:
        self.skip()
        if self.s[self.i] != "=":
            raise self.error("ожидалось =")
        self.i += 1


def parse_assignments(text: str) -> dict:
    """Все присваивания верхнего уровня: {"HordeChronicleDB": {...}, ...}"""
    p = _Parser(text.lstrip("\ufeff"))
    result = {}
    while True:
        p.skip()
        if p.i >= len(p.s):
            return result
        m = _NAME.match(p.s, p.i)
        if not m:
            raise p.error("ожидалось имя переменной")
        p.i = m.end()
        p.expect_eq()
        result[m.group(0)] = p.value()


def lua_string(text: str) -> str:
    """Строка Lua в двойных кавычках. «|» в WoW — начало кода форматирования, заменяем на «/»."""
    text = text.replace("|", "/")
    text = text.replace("\\", "\\\\").replace('"', '\\"').replace("\r", "").replace("\n", "\\n")
    return f'"{text}"'


def render_sagas(sagas: dict[str, str]) -> str:
    lines = ["-- Сказания ИИ-летописца. Файл перезаписывает tools/chronicle.py (Летопись_ИИ.bat) — руками не править.",
             "HordeChronicle_Sagas = {"]
    for key in sorted(sagas):
        lines.append(f"  [{lua_string(key)}] = {lua_string(sagas[key])},")
    lines.append("}")
    return "\n".join(lines) + "\n"
