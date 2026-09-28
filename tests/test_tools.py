"""ИИ-летописец: разбор SavedVariables, запись Sagas.lua, промпт, сквозной прогон с подменой Ollama."""
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "tools"))

import chronicle  # noqa: E402
from savedvars import parse_assignments, render_sagas  # noqa: E402

SAMPLE = '''
HordeChronicleDB = {
\t["settings"] = {
\t\t["channel"] = "guild",
\t\t["toast"] = true,
\t\t["screenshot"] = false,
\t},
\t["kills"] = {
\t\t{
\t\t\t["id"] = "Громмаш-Пламегор:1790000000:1",
\t\t\t["hero"] = "Громмаш-Пламегор",
\t\t\t["killer"] = "me",
\t\t\t["date"] = "04.11.2026 21:15",
\t\t\t["zone"] = "Предгорья Хилсбрада",
\t\t\t["subzone"] = "Южнобережье",
\t\t\t["streak"] = 3,
\t\t\t["meet"] = 2,
\t\t\t["mySex"] = 2,
\t\t\t["myLevel"] = 60,
\t\t\t["spells"] = {
\t\t\t\t"Казнь", -- [1]
\t\t\t\t"Удар героя", -- [2]
\t\t\t},
\t\t\t["text"] = "Паладин \\"Ламберт\\" пал.\\nЗа Орду!",
\t\t\t["victim"] = {
\t\t\t\t["name"] = "Ламберт",
\t\t\t\t["class"] = "PALADIN",
\t\t\t\t["race"] = "Dwarf",
\t\t\t\t["sex"] = 2,
\t\t\t\t["level"] = 61,
\t\t\t\t["realm"] = "",
\t\t\t},
\t\t}, -- [1]
\t\t{
\t\t\t["id"] = "Громмаш-Пламегор:test:1790000100:2",
\t\t\t["test"] = true,
\t\t\t["victim"] = { ["name"] = "Тест" },
\t\t}, -- [2]
\t},
}
'''


def test_parse_savedvariables():
    db = parse_assignments(SAMPLE)["HordeChronicleDB"]
    assert db["settings"]["channel"] == "guild" and db["settings"]["toast"] is True
    k = db["kills"][0]
    assert k["victim"]["name"] == "Ламберт" and k["victim"]["level"] == 61
    assert k["spells"] == ["Казнь", "Удар героя"]
    assert k["text"] == 'Паладин "Ламберт" пал.\nЗа Орду!'
    assert len(db["kills"]) == 2


def test_decimal_byte_escapes_decode_utf8():
    # WoW иногда пишет не-ASCII как \ddd
    raw = "".join(f"\\{b}" for b in "Орда".encode("utf-8"))
    assert parse_assignments(f'X = "{raw}"')["X"] == "Орда"


def test_render_sagas_roundtrip_with_quotes_newlines_and_pipes():
    sagas = {"a:1": 'Он сказал "Лок\'тар"\nи ударил | насмерть', "b:2": "Просто текст\\путь"}
    back = parse_assignments(render_sagas(sagas))["HordeChronicle_Sagas"]
    assert back["a:1"] == 'Он сказал "Лок\'тар"\nи ударил / насмерть'
    assert back["b:2"] == "Просто текст\\путь"


def test_facts_contain_only_record_data():
    rec = parse_assignments(SAMPLE)["HordeChronicleDB"]["kills"][0]
    f = chronicle.facts(rec)
    assert f["враг"] == "Ламберт" and f["класс врага"] == "паладин" and f["народ врага"] == "дворф из Стальгорна"
    assert "3-я подряд" in f["серия"] and f["время суток"] == "вечер" and f["какая по счёту победа над этим врагом"] == 2
    assert f["последние заклинания героя"] == ["Казнь", "Удар героя"]
    assert not any("урон" in str(k) for k in f)


def test_saga_quality_gate():
    rec = {"victim": {"name": "Ламберт"}}
    assert not chronicle.good_saga("Слишком коротко про Ламберт.", rec)
    long_without_name = " ".join(["слово"] * 80)
    assert not chronicle.good_saga(long_without_name, rec)
    assert chronicle.good_saga(long_without_name + " Ламберт", rec)
    assert chronicle.good_saga(long_without_name + " сразил Ламберта", rec)
    assert chronicle.clean_saga("«**Сказание** о битве»") == "Сказание о битве"


def test_run_end_to_end_with_fake_ollama(tmp_path, monkeypatch):
    sv = tmp_path / "HordeChronicle.lua"
    sv.write_text(SAMPLE, encoding="utf-8")
    monkeypatch.setattr(chronicle, "SAGAS_FILE", tmp_path / "Sagas.lua")
    monkeypatch.setattr(chronicle, "HTML_FILE", tmp_path / "chronicle.html")
    calls = []

    def fake_ask(rec, model, tone=None):
        calls.append(rec["id"])
        return "Сказание: " + " ".join(["доблесть"] * 70) + " — так пал Ламберт в Южнобережье."

    res = chronicle.run(str(sv), ask=fake_ask, log=lambda *_: None)
    assert (res["written"], res["failed"], res["total"]) == (1, 0, 1)
    assert calls == ["Громмаш-Пламегор:1790000000:1"]          # тестовая запись пропущена
    sagas = parse_assignments((tmp_path / "Sagas.lua").read_text(encoding="utf-8"))["HordeChronicle_Sagas"]
    assert "Ламберт" in sagas["Громмаш-Пламегор:1790000000:1"]
    page = (tmp_path / "chronicle.html").read_text(encoding="utf-8")
    assert "Паладин Ламберт" in page and "доблесть" in page

    # второй прогон: уже написанное не переписывается
    calls.clear()
    res2 = chronicle.run(str(sv), ask=fake_ask, log=lambda *_: None)
    assert res2["written"] == 0 and calls == []


def test_ollama_down_does_not_crash(tmp_path, monkeypatch):
    sv = tmp_path / "HordeChronicle.lua"
    sv.write_text(SAMPLE, encoding="utf-8")
    monkeypatch.setattr(chronicle, "SAGAS_FILE", tmp_path / "Sagas.lua")
    monkeypatch.setattr(chronicle, "HTML_FILE", tmp_path / "chronicle.html")

    def down(rec, model, tone=None):
        raise ConnectionError("нет связи")

    res = chronicle.run(str(sv), ask=down, log=lambda *_: None)
    assert res["written"] == 0 and res["failed"] == 1
    assert (tmp_path / "Sagas.lua").exists()


def test_sagas_go_into_installed_addon_folder(tmp_path, monkeypatch):
    # поддельная игра: World of Warcraft\_classic_beta_\{Interface\AddOns\HordeChronicle, WTF\...\SavedVariables}
    client = tmp_path / "World of Warcraft" / "_classic_beta_"
    addon = client / "Interface" / "AddOns" / "HordeChronicle"
    addon.mkdir(parents=True)
    (addon / "Sagas.lua").write_text('HordeChronicle_Sagas = { ["old"] = "старое сказание" }\n', encoding="utf-8")
    sv = client / "WTF" / "Account" / "ACC123" / "SavedVariables" / "HordeChronicle.lua"
    sv.parent.mkdir(parents=True)
    sv.write_text(SAMPLE, encoding="utf-8")
    (client.parent / "_retail_").mkdir()          # другой клиент без аддона не мешает
    monkeypatch.setattr(chronicle, "HTML_FILE", tmp_path / "chronicle.html")
    monkeypatch.setattr(chronicle, "SAGAS_FILE", tmp_path / "repo_Sagas.lua")

    assert chronicle.clients([client.parent]) == [client]
    res = chronicle.run(roots=[client.parent], ask=lambda r, m, t=None: " ".join(["слава"] * 70) + " Ламберт", log=lambda *_: None)
    assert res["written"] == 1 and res["sagas_file"] == str(addon / "Sagas.lua")
    sagas = parse_assignments((addon / "Sagas.lua").read_text(encoding="utf-8"))["HordeChronicle_Sagas"]
    assert sagas["old"] == "старое сказание" and "Ламберт" in sagas["Громмаш-Пламегор:1790000000:1"]
    assert not (tmp_path / "repo_Sagas.lua").exists()


def test_clear_message_when_nothing_installed(tmp_path):
    import pytest
    with pytest.raises(SystemExit) as e:
        chronicle.locate(None, roots=[tmp_path])
    assert "Interface" in str(e.value) and "AddOns" in str(e.value)


def test_saga_tone_follows_addon_setting(tmp_path, monkeypatch):
    sv = tmp_path / "HordeChronicle.lua"
    sv.write_text(SAMPLE, encoding="utf-8")                       # в SAMPLE тон не задан → по умолчанию hard
    monkeypatch.setattr(chronicle, "SAGAS_FILE", tmp_path / "Sagas.lua")
    monkeypatch.setattr(chronicle, "HTML_FILE", tmp_path / "chronicle.html")
    seen = []
    chronicle.run(str(sv), ask=lambda r, m, t=None: seen.append(t) or " ".join(["х"] * 70) + " Ламберт", log=lambda *_: None)
    assert seen == ["hard"]
    assert "матом" in chronicle.system_prompt("hard") and "Без мата" in chronicle.system_prompt("mock")
    assert chronicle.system_prompt("нет такого") == chronicle.SYSTEM
