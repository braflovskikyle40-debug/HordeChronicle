"""Сборка публичного релиза: чистая копия проекта для GitHub + архив HordeChronicle.zip для установки.

Запуск: python tools/build_release.py <папка_вывода>
В папке появятся repo/ (содержимое публичного репозитория) и HordeChronicle.zip
(внутри — папка HordeChronicle, её распаковывают в Interface\\AddOns).
Сказания игрока (Sagas.lua) в релиз не попадают — кладётся пустой шаблон.
"""
from __future__ import annotations

import re
import shutil
import sys
import zipfile
from pathlib import Path

PROJECT = Path(__file__).resolve().parents[1]
ADDON = PROJECT / "HordeChronicle"
PUBLIC_FILES = [
    "tools/chronicle.py", "tools/savedvars.py", "tools/install.ps1", "tools/build_release.py",
    "tests/run.lua", "tests/test_tools.py",
    "Установить_в_WoW.bat", "Летопись_ИИ.bat", "LICENSE", "PUBLIC_README.md",
]
EMPTY_SAGAS = ("-- Сказания ИИ-летописца. Файл перезаписывает tools/chronicle.py (Летопись_ИИ.bat) — руками не править.\n"
               "HordeChronicle_Sagas = HordeChronicle_Sagas or {}\n")
GITIGNORE = "wow_path.txt\nchronicle.html\n__pycache__/\n.pytest_cache/\n.omc/\n"
# Имя пользователя Windows и папка рабочего пространства берутся с этой машины, а не пишутся в файл:
# иначе сам сборщик выдал бы их в публичном репозитории.
PRIVATE = re.compile("|".join([re.escape(Path.home().name), re.escape(PROJECT.parents[1].name),
                               r"C:[\\/]Users", r"@gmail\.", r"@mail\.ru", r"@outlook\."]), re.IGNORECASE)


def addon_files() -> list[Path]:
    return sorted(p for p in ADDON.iterdir() if p.is_file() and p.suffix in (".lua", ".toc"))


def version() -> str:
    m = re.search(r"^## Version:\s*(\S+)", (ADDON / "HordeChronicle.toc").read_text(encoding="utf-8"), re.M)
    return m.group(1) if m else "0.0.0"


def build(out: Path) -> tuple[Path, Path]:
    repo = out / "repo"
    if repo.exists():
        shutil.rmtree(repo)
    (repo / "HordeChronicle").mkdir(parents=True)
    for f in addon_files():
        text = EMPTY_SAGAS if f.name == "Sagas.lua" else f.read_text(encoding="utf-8")
        (repo / "HordeChronicle" / f.name).write_text(text, encoding="utf-8", newline="\n")
    for rel in PUBLIC_FILES:
        src = PROJECT / rel
        dst = repo / ("README.md" if rel == "PUBLIC_README.md" else rel)
        dst.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(src, dst)
    (repo / ".gitignore").write_text(GITIGNORE, encoding="utf-8")

    leaks = [str(p.relative_to(repo)) for p in repo.rglob("*") if p.is_file()
             and p.suffix not in (".bat",) and PRIVATE.search(p.read_text(encoding="utf-8", errors="ignore"))]
    if leaks:
        raise SystemExit(f"В релиз попали личные данные: {leaks}")

    zip_path = out / "HordeChronicle.zip"
    with zipfile.ZipFile(zip_path, "w", zipfile.ZIP_DEFLATED) as z:
        for f in sorted((repo / "HordeChronicle").iterdir()):
            z.write(f, f"HordeChronicle/{f.name}")
    return repo, zip_path


if __name__ == "__main__":
    target = Path(sys.argv[1] if len(sys.argv) > 1 else PROJECT / "release")
    repo_dir, zipped = build(target)
    print(f"Версия {version()}: {repo_dir} и {zipped}")
