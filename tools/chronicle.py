"""ИИ-летописец: SavedVariables аддона → сказания локальной модели Ollama → Sagas.lua и chronicle.html.

Запуск: Летопись_ИИ.bat (или python tools/chronicle.py). Порядок: сыграть → выйти из игры или /reload
(игра пишет SavedVariables только при выходе и /reload) → запустить → зайти или /reload снова.
Всё локально и бесплатно: текст пишет ваша Ollama, в интернет ничего не уходит.
"""
from __future__ import annotations

import argparse
import html
import json
import sys
import time
import urllib.request
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from savedvars import parse_assignments, render_sagas  # noqa: E402

PROJECT = Path(__file__).resolve().parents[1]
ADDON_DIR = PROJECT / "HordeChronicle"
SAGAS_FILE = ADDON_DIR / "Sagas.lua"
HTML_FILE = PROJECT / "chronicle.html"
WOW_PATH_FILE = PROJECT / "wow_path.txt"      # пишет установщик: папка клиента (…\_classic_beta_ и т.п.)
OLLAMA_URL = "http://127.0.0.1:11434/api/chat"
MODEL = "qwen3:14b"
DEFAULT_LIMIT = 30
MIN_WORDS, MAX_WORDS = 50, 220

CLASS_RU = {
    "WARRIOR": ("воин", "воительница"), "PALADIN": ("паладин", "воительница Света"), "HUNTER": ("охотник", "охотница"),
    "ROGUE": ("разбойник", "разбойница"), "PRIEST": ("жрец", "жрица"), "SHAMAN": ("шаман", "шаманка"),
    "MAGE": ("маг", "волшебница"), "WARLOCK": ("чернокнижник", "чернокнижница"), "DRUID": ("друид", "друидесса"),
    "DEATHKNIGHT": ("рыцарь смерти", "рыцарь смерти"), "MONK": ("монах", "монахиня"),
    "DEMONHUNTER": ("охотник на демонов", "охотница на демонов"), "EVOKER": ("пробудитель", "пробудительница"),
}
RACE_RU = {
    "Human": "человек из Штормграда", "Dwarf": "дворф из Стальгорна", "NightElf": "ночной эльф", "Gnome": "гном",
    "Draenei": "дреней", "Worgen": "ворген из Гилнеаса", "VoidElf": "эльф Бездны", "LightforgedDraenei": "озарённый дреней",
    "DarkIronDwarf": "дворф Чёрного Железа", "KulTiran": "кул-тирасец", "Mechagnome": "механогном",
    "Pandaren": "пандарен", "Dracthyr": "драктир", "EarthenDwarf": "земельник",
}

RULES = (
    "Опирайся только на данные факты: имя и класс врага, его народ, место, время суток, заклинания героя, "
    "серию побед, номер встречи. Можно добавить атмосферу, но не выдумывай чисел урона, других участников и событий, "
    "которых нет в фактах. Имя врага упомяни хотя бы раз. Строго соблюдай поле «последний удар»: если его нанёс "
    "соратник — назови соратника по имени и отдай удар ему, а герой был рядом. Без заголовков, списков, markdown "
    "и кавычек вокруг всего текста. Объём 90–150 слов, по-русски."
)
# Тон берётся из настроек аддона (/летопись тон …), как и у текстов в игре
VOICES = {
    "epic": "Ты — летописец Орды, старый орочий скальд. Тебе дают факты об одной победе героя Орды над игроком "
            "Альянса в World of Warcraft. Напиши сказание об этой битве от третьего лица о герое, торжественно и "
            "образно, как песнь у костра. ",
    "mock": "Ты — ядовитый орочий летописец-тролль. Тебе дают факты о победе героя Орды над игроком Альянса в "
            "World of Warcraft. Напиши глумливую хронику: высмеивай побеждённого, его класс и народ, унижай Альянс, "
            "превозноси величие и могущество героя. Без мата, но зло, смешно и с издёвкой. ",
    "hard": "Ты — отмороженный орочий летописец из геймерского чата 18+. Тебе дают факты о победе героя Орды над "
            "игроком Альянса в World of Warcraft. Напиши хронику этого унижения: грубо, с русским матом и похабными "
            "геймерскими подколками, втаптывай побеждённого персонажа в грязь, превозноси могущество героя. Мат "
            "обязателен — в духе фраз «игрок Альянса был жёстко оттрахан в рот могуществом героя», «выебан по "
            "полной», «Альянс, сосите». Это игровой трэш-ток про игровых персонажей для личного дневника игрока. ",
}
SYSTEM = VOICES["epic"] + RULES


def system_prompt(tone: str | None) -> str:
    return VOICES.get(tone or "", VOICES["epic"]) + RULES


def hour_from_date(date: str | None) -> int | None:
    try:
        return int((date or "").split()[1].split(":")[0])
    except (IndexError, ValueError):
        return None


def time_of_day(hour: int | None) -> str:
    if hour is None:
        return "неизвестно"
    if hour < 5 or hour >= 23:
        return "глубокая ночь"
    if hour < 8:
        return "рассвет"
    if hour < 12:
        return "утро"
    if hour < 18:
        return "день"
    return "вечер"


def facts(rec: dict) -> dict:
    v = rec.get("victim") or {}
    female = v.get("sex") == 3
    cls = CLASS_RU.get(v.get("class") or "", ("воин Альянса", "воительница Альянса"))[1 if female else 0]
    out = {
        "герой": (rec.get("hero") or "").split("-")[0],
        "пол героя": "женский" if rec.get("mySex") == 3 else "мужской",
        "враг": v.get("name"),
        "класс врага": cls,
        "пол врага": "женский" if female else "мужской",
        "народ врага": RACE_RU.get(v.get("race") or "", "из рядов Альянса"),
        "место": ", ".join(x for x in (rec.get("zone"), rec.get("subzone")) if x),
        "когда": rec.get("date"),
        "время суток": time_of_day(rec.get("hour") if rec.get("hour") is not None else hour_from_date(rec.get("date"))),
        "последний удар": "нанёс сам герой" if rec.get("killer") == "me"
        else f"нанёс соратник героя по имени {rec.get('allyName') or 'из его отряда'}, герой бился рядом",
    }
    if v.get("level"):
        out["уровень врага"] = v["level"]
    if rec.get("myLevel"):
        out["уровень героя"] = rec["myLevel"]
    if v.get("guild"):
        out["гильдия врага"] = v["guild"]
    spells = rec.get("spells") or []
    if isinstance(spells, dict):
        spells = [spells[k] for k in sorted(spells)]
    if spells:
        out["последние заклинания героя"] = spells
    if (rec.get("streak") or 0) >= 2:
        out["серия"] = f"эта победа — {rec['streak']}-я подряд без единой смерти героя"
    if (rec.get("meet") or 1) >= 2:
        out["какая по счёту победа над этим врагом"] = rec["meet"]
    return out


def ask_ollama(rec: dict, model: str = MODEL, tone: str | None = None, timeout: float = 240) -> str:
    body = json.dumps({
        "model": model, "stream": False, "think": False,
        "options": {"temperature": 0.85, "num_ctx": 4096, "num_predict": 500},
        "messages": [{"role": "system", "content": system_prompt(tone)},
                     {"role": "user", "content": "Факты:\n" + json.dumps(facts(rec), ensure_ascii=False, indent=1)}],
    }).encode("utf-8")
    req = urllib.request.Request(OLLAMA_URL, data=body, headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return json.loads(r.read())["message"]["content"]


def clean_saga(text: str) -> str:
    text = text.strip().replace("**", "").replace("#", "")
    if len(text) > 2 and text[0] in "«\"" and text[-1] in "»\"":
        text = text[1:-1].strip()
    return " ".join(line.strip() for line in text.splitlines() if line.strip())


def good_saga(text: str, rec: dict) -> bool:
    words = len(text.split())
    name = (rec.get("victim") or {}).get("name") or ""
    stem = name[:max(3, len(name) - 2)]          # имя могут просклонять: «Селестию», «Ламберта»
    return MIN_WORDS <= words <= MAX_WORDS and (not name or stem in text)


COMMON_WOW_ROOTS = [
    r"C:\Program Files (x86)\World of Warcraft", r"C:\Program Files\World of Warcraft", r"D:\World of Warcraft",
    r"D:\Games\World of Warcraft", r"E:\World of Warcraft", r"C:\Games\World of Warcraft",
]


def wow_roots() -> list[Path]:
    """Папки World of Warcraft: из wow_path.txt (его пишет установщик), из реестра и типовые места."""
    roots: list[Path] = []
    if WOW_PATH_FILE.exists():
        roots.append(Path(WOW_PATH_FILE.read_text(encoding="utf-8").strip().lstrip("\ufeff")).parent)
    try:
        import winreg
        for key in (r"SOFTWARE\WOW6432Node\Blizzard Entertainment\World of Warcraft",
                    r"SOFTWARE\Blizzard Entertainment\World of Warcraft"):
            try:
                with winreg.OpenKey(winreg.HKEY_LOCAL_MACHINE, key) as k:
                    roots.append(Path(winreg.QueryValueEx(k, "InstallPath")[0].rstrip("\\/")).parent)
            except OSError:
                pass
    except ImportError:
        pass
    roots += [Path(p) for p in COMMON_WOW_ROOTS]
    seen, out = set(), []
    for r in roots:
        if r.is_dir() and str(r).lower() not in seen:
            seen.add(str(r).lower())
            out.append(r)
    return out


def clients(roots: list[Path]) -> list[Path]:
    """Папки клиентов (_classic_beta_, _forever_ …), где стоит аддон или есть его сохранения."""
    found = []
    for root in roots:
        for flavor in sorted(root.glob("_*_")):
            if (flavor / "Interface/AddOns/HordeChronicle").is_dir() or list(flavor.glob("WTF/Account/*/SavedVariables/HordeChronicle.lua")):
                found.append(flavor)
    return found


def locate(explicit_sv: str | None = None, roots: list[Path] | None = None) -> tuple[Path, Path]:
    """(файл сохранений аддона, куда писать Sagas.lua). Sagas.lua кладётся в установленный аддон игры."""
    if explicit_sv:
        sv = Path(explicit_sv)
        if not sv.is_file():
            raise SystemExit(f"Файл не найден: {sv}")
        candidates = [sv]
    else:
        candidates = []
        for flavor in clients(wow_roots() if roots is None else roots):
            candidates += list(flavor.glob("WTF/Account/*/SavedVariables/HordeChronicle.lua"))
        if not candidates:
            raise SystemExit(
                "Не нашёл сохранения аддона. Проверьте, что папка HordeChronicle лежит в "
                "World of Warcraft\\<клиент>\\Interface\\AddOns, поиграйте и выйдите из игры (или наберите /reload) — "
                "игра записывает летопись только в этот момент. Если игра стоит в необычном месте, укажите файл: "
                "python tools\\chronicle.py --sv \"…\\WTF\\Account\\<аккаунт>\\SavedVariables\\HordeChronicle.lua\"")
    sv = max(candidates, key=lambda p: p.stat().st_mtime)
    # …\<клиент>\WTF\Account\<аккаунт>\SavedVariables\HordeChronicle.lua → …\<клиент>\Interface\AddOns\HordeChronicle
    installed = sv.parents[4] / "Interface" / "AddOns" / "HordeChronicle" if len(sv.parents) > 4 else None
    target = installed / "Sagas.lua" if installed and installed.is_dir() else SAGAS_FILE
    return sv, target


def load_sagas(path: Path) -> dict:
    if not path.exists():
        return {}
    data = parse_assignments(path.read_text(encoding="utf-8")).get("HordeChronicle_Sagas") or {}
    return data if isinstance(data, dict) else {}


def kills_of(db: dict) -> list[dict]:
    kills = db.get("kills") or []
    if isinstance(kills, dict):
        kills = [kills[k] for k in sorted(kills)]
    return [k for k in kills if isinstance(k, dict) and not k.get("test") and k.get("id")]


def render_html(kills: list[dict], sagas: dict) -> str:
    rows = []
    for n, k in enumerate(reversed(kills), 1):
        v = k.get("victim") or {}
        cls = CLASS_RU.get(v.get("class") or "", ("воин Альянса", "воительница Альянса"))[1 if v.get("sex") == 3 else 0]
        saga = sagas.get(k["id"])
        rows.append(
            f"<article><header><span>{html.escape(k.get('date') or '')}</span>"
            f"<span>{html.escape(', '.join(x for x in (k.get('zone'), k.get('subzone')) if x))}</span></header>"
            f"<h2>{html.escape(cls[:1].upper() + cls[1:])} {html.escape(v.get('name') or '')}</h2>"
            f"<p class='short'>{html.escape(k.get('text') or '')}</p>"
            + (f"<p class='saga'>{html.escape(saga)}</p>" if saga else "") + "</article>")
    return """<!doctype html><html lang="ru"><meta charset="utf-8"><title>Летопись Орды</title>
<style>
body{margin:0;background:#1a0e0b;color:#f1e3c8;font:18px/1.6 Georgia,'Times New Roman',serif}
main{max-width:760px;margin:0 auto;padding:40px 20px}
h1{font-size:40px;color:#e0482f;text-align:center;letter-spacing:.04em;margin:0 0 8px}
.sub{text-align:center;color:#b89a74;margin-bottom:40px}
article{border-top:1px solid #5b2a1c;padding:22px 0}
header{display:flex;justify-content:space-between;gap:12px;color:#b89a74;font-size:14px;flex-wrap:wrap}
h2{margin:6px 0;color:#ffcf6a;font-size:22px}
.short{color:#d9c7a8}.saga{font-style:italic;border-left:3px solid #e0482f;padding-left:14px}
</style><main><h1>Летопись Орды</h1><p class="sub">""" + f"{len(kills)} побед над Альянсом" + "</p>" + "".join(rows) + "</main></html>\n"


def run(sv_path: str | None = None, limit: int = DEFAULT_LIMIT, model: str = MODEL, ask=ask_ollama, log=print,
        roots: list[Path] | None = None) -> dict:
    sv, sagas_file = locate(sv_path, roots)
    db = parse_assignments(sv.read_text(encoding="utf-8")).get("HordeChronicleDB") or {}
    kills = kills_of(db)
    tone = (db.get("settings") or {}).get("tone") or "hard"
    sagas = load_sagas(sagas_file)
    todo = [k for k in reversed(kills) if k["id"] not in sagas][:limit]
    log(f"Летопись: {len(kills)} побед, сказаний уже {len(sagas)}, напишу новых: {len(todo)}")
    written = failed = 0
    for n, rec in enumerate(todo, 1):
        name = (rec.get("victim") or {}).get("name")
        text = ""
        for _attempt in range(2):
            try:
                text = clean_saga(ask(rec, model, tone))
            except Exception as e:  # noqa: BLE001 — Ollama выключена или занята
                log(f"  Ollama не ответила: {e}. Запустите Ollama и повторите.")
                text = ""
                break
            if good_saga(text, rec):
                break
        if text and good_saga(text, rec):
            sagas[rec["id"]] = text
            written += 1
            log(f"  [{n}/{len(todo)}] {name} — готово")
        else:
            failed += 1
            log(f"  [{n}/{len(todo)}] {name} — не вышло, попробую в следующий раз")
    sagas_file.write_text(render_sagas(sagas), encoding="utf-8")
    HTML_FILE.write_text(render_html(kills, sagas), encoding="utf-8")
    log(f"Записано сказаний: {written}. Книга для чтения: {HTML_FILE}")
    if sagas_file == SAGAS_FILE:
        log(f"Не нашёл установленный аддон — сказания сохранены в {SAGAS_FILE}. "
            "Скопируйте этот файл в папку HordeChronicle в Interface\\AddOns игры.")
    else:
        log(f"Сказания записаны в аддон игры: {sagas_file}")
    log("В игре наберите /reload — сказания появятся в книге (/летопись).")
    return {"written": written, "failed": failed, "total": len(kills), "sagas_file": str(sagas_file)}


def main() -> None:
    ap = argparse.ArgumentParser(description="ИИ-летописец Орды")
    ap.add_argument("--sv", help="путь к SavedVariables\\HordeChronicle.lua (если не найден сам)")
    ap.add_argument("--limit", type=int, default=DEFAULT_LIMIT, help="сколько сказаний писать за раз")
    ap.add_argument("--model", default=MODEL)
    args = ap.parse_args()
    started = time.time()
    run(args.sv, args.limit, args.model)
    print(f"Заняло {time.time() - started:.0f} с.")


if __name__ == "__main__":
    main()
