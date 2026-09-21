# Станция прошивки — план реализации

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Кроссплатформенная станция на Python, которая ведёт роутер Cudy от заводского состояния до чистого официального OpenWrt: закреплённые суммы, обратное чтение загрузчика до перезагрузки, обязательная копия Factory, один заход.

**Architecture:** Пакет `station/` с модулями по одной ответственности. Ядро (`mtd`, `flow`, `artifacts`, `tftp`, `passport`, `commands`, `handlers`) не знает о настоящем роутере — оно работает через объект `Remote` с четырьмя методами. Это граница, по которой всё проверяется в CI без железа. Модули `stock_ui` (Playwright) и `ssh_remote` (paramiko) — единственные, кому нужно живое устройство.

**Tech Stack:** Python 3.11+, paramiko (SSH), Playwright (заводской веб-интерфейс), стандартная библиотека для TFTP и HTTP.

## Global Constraints

- Python 3.11+; работает на macOS, Linux, Windows.
- Пакет в каталоге `station/`, запуск `python -m station`.
- Версия OpenWrt закреплена: **25.12.4**. Не «последняя».
- **Контрольные суммы официальных файлов закреплены в коде** (ниже, verbatim). Скачанный `sha256sums` используется как дополнительная сверка, но доверие — к закреплённым константам. Это закрывает долг `docs/AUDIT.md`: «закрепить SHA-256 runtime-модулей в манифесте релиза».
- Сторонние файлы (`settings_v2_@keeneticported.bin`, `mtd-rw.ko`) в репозиторий **не кладутся**: берутся из `~/.flashing-station/assets/`, принимаются только по закреплённой sha256.
- Рабочий каталог — `~/.flashing-station/` (`assets/`, `cache/`, `devices/<serial>/`).
- **Ключ устройства — серийный номер**, он обязателен аргументом `--serial`. Так решается и возобновление (MAC ещё неизвестен на первых шагах), и заполнение паспорта.
- Каждый шаг либо подтверждён проверкой, либо станция останавливается с понятным сообщением. Отказы тоже записываются в журнал.
- Пароли в файлы не пишутся.
- Плата в OpenWrt и в `ubus call system board` пишется **через запятую**: `cudy,wbr3000uax-v1`. В именах файлов образов — **через подчёркивание**: `cudy_wbr3000uax-v1`. Это два разных поля, путать нельзя.
- Закреплённые суммы OpenWrt 25.12.4 (`mediatek/filogic`):

| Модель | Файл | sha256 |
|---|---|---|
| WBR3000UAX | preloader.bin | `3eb3fb83edb5eb008b9ac8cf8f31a9d6eb65d1093edff749d4763aca4d96945c` |
| WBR3000UAX | bl31-uboot.fip | `d7fcfca879ec77bd47e9c470b974f7cccc166b1b429cadf9ca12d410b25977c0` |
| WBR3000UAX | initramfs-recovery.itb | `075a1088b7de983900b4d04b698a6872d2e1ab75d3cf4b9d9dfc1f4ff678d12c` |
| WBR3000UAX | squashfs-sysupgrade.itb | `97ec9a4dc45f11db0408fe1c7ec70990ae9854dab74deb4eb46b9f3dbe5f4810` |
| WR3000S | preloader.bin | `3eb3fb83edb5eb008b9ac8cf8f31a9d6eb65d1093edff749d4763aca4d96945c` |
| WR3000S | bl31-uboot.fip | `015204ced4e353b4677c15dcbf993a5c28d373633d7a52f86feff4965e36ee06` |
| WR3000S | initramfs-recovery.itb | `83eac438abd8360a1026fee6eb69c0df5a446600282d7b1b6467a2057d798c44` |
| WR3000S | squashfs-sysupgrade.itb | `3708422b64bdb5d650dfeb0c828144a21c1d5465580090cda73892a3fd8258c1` |

- Сторонние файлы (сняты с разобранного экземпляра утилиты, WBR3000UAX):
  - `mtd-rw.ko` — `1ad25a1ea33a9467aa4e0db87647a0b16e125b79bf1c5241f67f5d050e026787`, 5320 байт;
  - `settings_v2_@keeneticported.bin` — `df725c26662321f0b65cfab26197634cef76629fc124b69eb49d436c309a0e66`, 23334 байта.
  - **Для WR3000S сумма файла настроек неизвестна.** У этой модели `settings_backup = None`, и станция откажется открывать доступ, пока сумму не подтвердят на живом железе.

- Соответствие файл → раздел (единственный необратимый шаг, ошибка здесь стоит устройства):
  - `preloader.bin` → раздел `BL2`
  - `bl31-uboot.fip` → раздел `FIP`
- Порядок записи: сначала `FIP`, затем `BL2` — как в разобранной утилите.
- Адреса: заводской `192.168.10.1`, восстановление `192.168.1.1`, адрес ПК для TFTP `192.168.1.254/24`.
- Раздел sysupgrade называется `ubi`; тома — `ubootenv` и `ubootenv2` по 128 KiB.

---

### Task 1: Модели, соответствие файл→раздел, явный отказ

**Files:**
- Create: `station/__init__.py`
- Create: `station/models.py`
- Test: `station/tests/__init__.py`
- Test: `station/tests/test_models.py`

**Interfaces:**
- Produces:
  - `@dataclass(frozen=True) Artifact(kind: str, filename: str, sha256: str)`
  - `@dataclass(frozen=True) WriteTarget(artifact_kind: str, partition: str)`
  - `@dataclass(frozen=True) ThirdPartyFile(name: str, sha256: str, size: int)`
  - `@dataclass(frozen=True) Model(key, board_ubus, board_file, openwrt_version, stock_ip, recovery_ip, tested, artifacts, writes, required_partitions, settings_backup, mtd_rw, known_stock_versions)`
  - `MODELS: dict[str, Model]`, `UNSUPPORTED: dict[str, str]`
  - `find_model(board_ubus: str) -> Model | None`
  - `unsupported_reason(board_ubus: str) -> str | None`
  - `artifact(model: Model, kind: str) -> Artifact`
  - `VERSION: str` — версия станции, `"0.1.0"`

- [ ] **Step 1: Написать падающий тест**

```python
# station/tests/test_models.py
import pytest
from station.models import (MODELS, UNSUPPORTED, find_model, unsupported_reason,
                            artifact, VERSION)

def test_board_lookup_uses_comma_form():
    assert find_model("cudy,wbr3000uax-v1").key == "cudy_wbr3000uax-v1"
    assert find_model("cudy,wr3000s-v1").key == "cudy_wr3000s-v1"

def test_board_file_and_board_ubus_differ():
    m = MODELS["cudy_wbr3000uax-v1"]
    assert m.board_ubus == "cudy,wbr3000uax-v1"
    assert m.board_file == "cudy_wbr3000uax-v1"

def test_unsupported_model_has_reason():
    assert find_model("cudy,wr3000-v1") is None
    reason = unsupported_reason("cudy,wr3000-v1")
    assert reason and "16" in reason

def test_write_mapping_is_explicit_and_ordered():
    m = MODELS["cudy_wbr3000uax-v1"]
    assert [(w.artifact_kind, w.partition) for w in m.writes] == [
        ("fip", "FIP"), ("preloader", "BL2")]

def test_every_artifact_has_pinned_sha256():
    for m in MODELS.values():
        for a in m.artifacts:
            assert len(a.sha256) == 64, f"{m.key}/{a.kind}"

def test_preloader_is_shared_between_models():
    a = artifact(MODELS["cudy_wbr3000uax-v1"], "preloader")
    b = artifact(MODELS["cudy_wr3000s-v1"], "preloader")
    assert a.sha256 == b.sha256

def test_wr3000s_has_no_confirmed_settings_backup():
    assert MODELS["cudy_wr3000s-v1"].settings_backup is None
    assert MODELS["cudy_wbr3000uax-v1"].settings_backup is not None

def test_factory_is_required_for_both():
    for m in MODELS.values():
        assert "Factory" in m.required_partitions

def test_station_version_present():
    assert VERSION.count(".") == 2
```

- [ ] **Step 2: Запустить, убедиться что падает**

Run: `python -m pytest station/tests/test_models.py -v`
Expected: FAIL, `ModuleNotFoundError: No module named 'station'`

- [ ] **Step 3: Написать модуль**

`station/__init__.py` и `station/tests/__init__.py` — пустые файлы.

```python
# station/models.py
from dataclasses import dataclass

VERSION = "0.1.0"
OPENWRT_VERSION = "25.12.4"

@dataclass(frozen=True)
class Artifact:
    kind: str          # preloader | fip | recovery | sysupgrade
    filename: str
    sha256: str

@dataclass(frozen=True)
class WriteTarget:
    artifact_kind: str
    partition: str

@dataclass(frozen=True)
class ThirdPartyFile:
    name: str
    sha256: str
    size: int

@dataclass(frozen=True)
class Model:
    key: str
    board_ubus: str
    board_file: str
    openwrt_version: str
    stock_ip: str
    recovery_ip: str
    tested: bool
    artifacts: tuple
    writes: tuple
    required_partitions: tuple
    settings_backup: ThirdPartyFile | None
    mtd_rw: ThirdPartyFile
    known_stock_versions: tuple

_NAME = "openwrt-{v}-mediatek-filogic-{b}-ubootmod-{s}"

_SUMS = {
    "cudy_wbr3000uax-v1": {
        "preloader": "3eb3fb83edb5eb008b9ac8cf8f31a9d6eb65d1093edff749d4763aca4d96945c",
        "fip": "d7fcfca879ec77bd47e9c470b974f7cccc166b1b429cadf9ca12d410b25977c0",
        "recovery": "075a1088b7de983900b4d04b698a6872d2e1ab75d3cf4b9d9dfc1f4ff678d12c",
        "sysupgrade": "97ec9a4dc45f11db0408fe1c7ec70990ae9854dab74deb4eb46b9f3dbe5f4810",
    },
    "cudy_wr3000s-v1": {
        "preloader": "3eb3fb83edb5eb008b9ac8cf8f31a9d6eb65d1093edff749d4763aca4d96945c",
        "fip": "015204ced4e353b4677c15dcbf993a5c28d373633d7a52f86feff4965e36ee06",
        "recovery": "83eac438abd8360a1026fee6eb69c0df5a446600282d7b1b6467a2057d798c44",
        "sysupgrade": "3708422b64bdb5d650dfeb0c828144a21c1d5465580090cda73892a3fd8258c1",
    },
}

_SUFFIX = {
    "preloader": "preloader.bin",
    "fip": "bl31-uboot.fip",
    "recovery": "initramfs-recovery.itb",
    "sysupgrade": "squashfs-sysupgrade.itb",
}

def _artifacts(board_file: str) -> tuple:
    return tuple(
        Artifact(kind,
                 _NAME.format(v=OPENWRT_VERSION, b=board_file, s=suffix),
                 _SUMS[board_file][kind])
        for kind, suffix in _SUFFIX.items()
    )

# Порядок важен: сначала FIP, затем BL2 — как в разобранной утилите.
_WRITES = (WriteTarget("fip", "FIP"), WriteTarget("preloader", "BL2"))

_MTD_RW = ThirdPartyFile(
    "mtd-rw.ko",
    "1ad25a1ea33a9467aa4e0db87647a0b16e125b79bf1c5241f67f5d050e026787",
    5320,
)

MODELS: dict[str, Model] = {
    "cudy_wbr3000uax-v1": Model(
        key="cudy_wbr3000uax-v1",
        board_ubus="cudy,wbr3000uax-v1",
        board_file="cudy_wbr3000uax-v1",
        openwrt_version=OPENWRT_VERSION,
        stock_ip="192.168.10.1",
        recovery_ip="192.168.1.1",
        tested=True,
        artifacts=_artifacts("cudy_wbr3000uax-v1"),
        writes=_WRITES,
        required_partitions=("Factory", "BL2", "FIP", "ubi"),
        settings_backup=ThirdPartyFile(
            "settings_v2_@keeneticported.bin",
            "df725c26662321f0b65cfab26197634cef76629fc124b69eb49d436c309a0e66",
            23334),
        mtd_rw=_MTD_RW,
        known_stock_versions=(),
    ),
    "cudy_wr3000s-v1": Model(
        key="cudy_wr3000s-v1",
        board_ubus="cudy,wr3000s-v1",
        board_file="cudy_wr3000s-v1",
        openwrt_version=OPENWRT_VERSION,
        stock_ip="192.168.10.1",
        recovery_ip="192.168.1.1",
        tested=False,
        artifacts=_artifacts("cudy_wr3000s-v1"),
        writes=_WRITES,
        required_partitions=("Factory", "BL2", "FIP", "ubi"),
        settings_backup=None,  # сумма не подтверждена на железе
        mtd_rw=_MTD_RW,
        known_stock_versions=(),
    ),
}

UNSUPPORTED: dict[str, str] = {
    "cudy,wr3000-v1": ("Cudy WR3000 v1: 16 МБ флеш-памяти. NetShift требует "
                       "не меньше 20 МБ свободных, эта модель не подходит "
                       "намеренно."),
}

def find_model(board_ubus: str) -> Model | None:
    for m in MODELS.values():
        if m.board_ubus == board_ubus:
            return m
    return None

def unsupported_reason(board_ubus: str) -> str | None:
    return UNSUPPORTED.get(board_ubus)

def artifact(model: Model, kind: str) -> Artifact:
    for a in model.artifacts:
        if a.kind == kind:
            return a
    raise KeyError(f"{model.key}: нет артефакта {kind}")
```

- [ ] **Step 4: Запустить, убедиться что проходит**

Run: `python -m pytest station/tests/test_models.py -v`
Expected: PASS (9 passed)

- [ ] **Step 5: Коммит**

```bash
git add station/__init__.py station/models.py station/tests/__init__.py station/tests/test_models.py
git commit -m "feat(station): модели, закреплённые суммы, соответствие файл-раздел"
```

---

### Task 2: Зависимости и джоба CI

**Files:**
- Create: `pyproject.toml`
- Modify: `.github/workflows/ci.yml`

**Interfaces:**
- Produces: устанавливаемый пакет `station` с зависимостями `paramiko`, `playwright`; dev-зависимость `pytest`. Джоба `station` в CI на трёх ОС.

Задача идёт второй, потому что все последующие ставят зависимости и запускают `pytest`. Без неё Task 11 упадёт на `git add pyproject.toml`.

- [ ] **Step 1: Создать `pyproject.toml`**

```toml
[project]
name = "flashing-station"
version = "0.1.0"
description = "Станция прошивки роутеров Cudy на OpenWrt"
requires-python = ">=3.11"
dependencies = [
    "paramiko>=3.4,<4",
    "playwright>=1.44,<2",
]

[project.optional-dependencies]
dev = ["pytest>=8,<9"]

[build-system]
requires = ["setuptools>=68"]
build-backend = "setuptools.build_meta"

[tool.setuptools]
packages = ["station"]

[tool.pytest.ini_options]
testpaths = ["station/tests"]
```

- [ ] **Step 2: Проверить, что пакет ставится**

Run: `python -m pip install -e . --dry-run`
Expected: разбор `pyproject.toml` без ошибок

- [ ] **Step 3: Добавить джобу в `.github/workflows/ci.yml`**

Вставить после джобы `shell`, на том же уровне отступа:

```yaml
  station:
    strategy:
      fail-fast: false
      matrix:
        os: [ubuntu-latest, macos-latest, windows-latest]
    runs-on: ${{ matrix.os }}
    timeout-minutes: 10

    steps:
      - name: Checkout
        uses: actions/checkout@v6
      - name: Set up Python
        uses: actions/setup-python@v5
        with:
          python-version: "3.11"
      - name: Install
        run: |
          python -m pip install --upgrade pip
          python -m pip install -e ".[dev]"
      - name: Tests
        run: python -m pytest station/tests -v
```

Матрица из трёх ОС нужна потому, что кроссплатформенность — заявленное свойство станции; проверять её только на Linux бессмысленно.

- [ ] **Step 4: Проверить синтаксис workflow**

Run: `python -c "import yaml,sys; yaml.safe_load(open('.github/workflows/ci.yml')); print('ok')"`
Expected: `ok`

- [ ] **Step 5: Коммит**

```bash
git add pyproject.toml .github/workflows/ci.yml
git commit -m "build(station): пакет, зависимости и джоба CI на трёх ОС"
```

---

### Task 3: Официальные файлы с закреплёнными суммами

**Files:**
- Create: `station/artifacts.py`
- Test: `station/tests/test_artifacts.py`

**Interfaces:**
- Consumes: `Model`, `artifact` из `station.models`
- Produces:
  - `class ArtifactError(Exception)`
  - `parse_sha256sums(text: str) -> dict[str, str]`
  - `sha256_file(path) -> str`
  - `sha256_bytes(data: bytes) -> str`
  - `ensure_artifacts(model, cache_dir, fetch) -> dict[str, pathlib.Path]` — сверяет сначала с **закреплённой** суммой, затем дополнительно с `sha256sums`; расхождение любого из двух → `ArtifactError`

- [ ] **Step 1: Написать падающий тест**

Настоящие закреплённые суммы соответствуют многомегабайтным файлам, подделать
которые в тесте нельзя. Поэтому проверяем на синтетической модели, где суммы
посчитаны от коротких тел — логика от этого не меняется.

```python
# station/tests/test_artifacts.py
import pytest
from station.models import Artifact, Model, ThirdPartyFile
from station.artifacts import (parse_sha256sums, ensure_artifacts, sha256_bytes,
                               ArtifactError)

def test_parse_handles_one_and_two_spaces():
    # sha256sum -b печатает два пробела; downloads.openwrt.org — один
    got = parse_sha256sums("aaa *one.itb\nbbb  *two.bin\nccc  three.bin\n")
    assert got["one.itb"] == "aaa"
    assert got["two.bin"] == "bbb"
    assert got["three.bin"] == "ccc"

def _model(bodies: dict) -> Model:
    arts = tuple(Artifact(kind, f"file-{kind}.bin", sha256_bytes(body))
                 for kind, body in bodies.items())
    return Model(key="test", board_ubus="t,t-v1", board_file="t_t-v1",
                 openwrt_version="25.12.4", stock_ip="192.168.10.1",
                 recovery_ip="192.168.1.1", tested=True, artifacts=arts,
                 writes=(), required_partitions=(), settings_backup=None,
                 mtd_rw=ThirdPartyFile("m", "0" * 64, 1), known_stock_versions=())

def _fetch(by_name: dict, sums_text: str):
    def fetch(url):
        name = url.rsplit("/", 1)[1]
        return sums_text.encode() if name == "sha256sums" else by_name[name]
    return fetch

def _sums(by_name: dict) -> str:
    return "".join(f"{sha256_bytes(v)} *{k}\n" for k, v in by_name.items())

def test_downloads_and_verifies(tmp_path):
    bodies = {"preloader": b"P-body", "fip": b"F-body"}
    m = _model(bodies)
    by_name = {a.filename: bodies[a.kind] for a in m.artifacts}
    paths = ensure_artifacts(m, tmp_path, _fetch(by_name, _sums(by_name)))
    assert paths["fip"].read_bytes() == b"F-body"

def test_pinned_sum_beats_a_self_consistent_server(tmp_path):
    # сервер отдаёт другое тело И согласованный с ним sha256sums —
    # станция обязана отказать, потому что доверяет коду, а не серверу
    m = _model({"preloader": b"P-body"})
    by_name = {a.filename: b"TAMPERED" for a in m.artifacts}
    with pytest.raises(ArtifactError) as e:
        ensure_artifacts(m, tmp_path, _fetch(by_name, _sums(by_name)))
    assert "закреплённой" in str(e.value)

def test_server_announcing_other_sum_stops_the_run(tmp_path):
    bodies = {"preloader": b"P-body"}
    m = _model(bodies)
    by_name = {a.filename: bodies[a.kind] for a in m.artifacts}
    bad_sums = "".join(f"{'0' * 64} *{k}\n" for k in by_name)
    with pytest.raises(ArtifactError) as e:
        ensure_artifacts(m, tmp_path, _fetch(by_name, bad_sums))
    assert "объявляет" in str(e.value)

def test_cached_file_is_not_refetched(tmp_path):
    bodies = {"preloader": b"P-body"}
    m = _model(bodies)
    by_name = {a.filename: bodies[a.kind] for a in m.artifacts}
    for a in m.artifacts:
        (tmp_path / a.filename).write_bytes(bodies[a.kind])
    asked = []
    def fetch(url):
        asked.append(url)
        return _sums(by_name).encode() if url.endswith("sha256sums") else b"NO"
    ensure_artifacts(m, tmp_path, fetch)
    assert asked == [u for u in asked if u.endswith("sha256sums")]
```

- [ ] **Step 2: Запустить, убедиться что падает**

Run: `python -m pytest station/tests/test_artifacts.py -v`
Expected: FAIL, `ModuleNotFoundError: No module named 'station.artifacts'`

- [ ] **Step 3: Написать модуль**

```python
# station/artifacts.py
import hashlib, pathlib
from typing import Callable
from .models import Model

BASE = "https://downloads.openwrt.org/releases/{v}/targets/mediatek/filogic/"

class ArtifactError(Exception):
    pass

def parse_sha256sums(text: str) -> dict[str, str]:
    out = {}
    for raw in text.splitlines():
        line = raw.strip()
        if not line:
            continue
        digest, _, rest = line.partition(" ")
        name = rest.strip().lstrip("*").strip()   # strip ДО lstrip('*')
        if name:
            out[name] = digest.strip()
    return out

def sha256_bytes(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()

def sha256_file(path: pathlib.Path) -> str:
    h = hashlib.sha256()
    with pathlib.Path(path).open("rb") as f:
        for chunk in iter(lambda: f.read(65536), b""):
            h.update(chunk)
    return h.hexdigest()

def ensure_artifacts(model: Model, cache_dir: pathlib.Path,
                     fetch: Callable[[str], bytes]) -> dict[str, pathlib.Path]:
    cache_dir = pathlib.Path(cache_dir)
    cache_dir.mkdir(parents=True, exist_ok=True)
    base = BASE.format(v=model.openwrt_version)
    published = parse_sha256sums(fetch(base + "sha256sums").decode("utf-8", "replace"))

    paths = {}
    for art in model.artifacts:
        dest = cache_dir / art.filename
        if not dest.exists() or sha256_file(dest) != art.sha256:
            dest.write_bytes(fetch(base + art.filename))

        got = sha256_file(dest)
        if got != art.sha256:
            raise ArtifactError(
                f"{art.filename}: сумма {got} не совпала с закреплённой "
                f"{art.sha256}. Файл подменён или версия OpenWrt изменилась.")

        announced = published.get(art.filename)
        if announced is not None and announced != art.sha256:
            raise ArtifactError(
                f"{art.filename}: сервер объявляет {announced}, "
                f"а в коде закреплено {art.sha256}. Разберитесь вручную.")

        paths[art.kind] = dest
    return paths
```

- [ ] **Step 4: Запустить, убедиться что проходит**

Run: `python -m pytest station/tests/test_artifacts.py -v`
Expected: PASS (5 passed)

- [ ] **Step 5: Коммит**

```bash
git add station/artifacts.py station/tests/test_artifacts.py
git commit -m "feat(station): официальные файлы с закреплёнными суммами"
```

---

### Task 4: Сторонние файлы из локального каталога

**Files:**
- Create: `station/thirdparty.py`
- Test: `station/tests/test_thirdparty.py`

**Interfaces:**
- Consumes: `ThirdPartyFile`, `sha256_file`, `ArtifactError`
- Produces: `load_thirdparty(spec: ThirdPartyFile | None, assets_dir) -> pathlib.Path` — при `spec is None` бросает `ArtifactError` с объяснением, что для этой модели файл не подтверждён

- [ ] **Step 1: Написать падающий тест**

```python
# station/tests/test_thirdparty.py
import hashlib, pytest
from station.models import ThirdPartyFile
from station.artifacts import ArtifactError
from station.thirdparty import load_thirdparty

def _spec(body: bytes) -> ThirdPartyFile:
    return ThirdPartyFile("mtd-rw.ko", hashlib.sha256(body).hexdigest(), len(body))

def test_loads_matching_file(tmp_path):
    body = b"kernel-module-body"
    (tmp_path / "mtd-rw.ko").write_bytes(body)
    assert load_thirdparty(_spec(body), tmp_path).read_bytes() == body

def test_missing_file_names_the_directory(tmp_path):
    with pytest.raises(ArtifactError) as e:
        load_thirdparty(_spec(b"x"), tmp_path)
    assert "mtd-rw.ko" in str(e.value) and str(tmp_path) in str(e.value)

def test_wrong_hash_rejected(tmp_path):
    (tmp_path / "mtd-rw.ko").write_bytes(b"different")
    with pytest.raises(ArtifactError):
        load_thirdparty(_spec(b"expected"), tmp_path)

def test_none_spec_explains_unconfirmed_model(tmp_path):
    with pytest.raises(ArtifactError) as e:
        load_thirdparty(None, tmp_path)
    assert "не подтвержд" in str(e.value)
```

- [ ] **Step 2: Запустить, убедиться что падает**

Run: `python -m pytest station/tests/test_thirdparty.py -v`
Expected: FAIL, `ModuleNotFoundError`

- [ ] **Step 3: Написать модуль**

```python
# station/thirdparty.py
import pathlib
from .models import ThirdPartyFile
from .artifacts import ArtifactError, sha256_file

def load_thirdparty(spec: ThirdPartyFile | None, assets_dir) -> pathlib.Path:
    if spec is None:
        raise ArtifactError(
            "Для этой модели сторонний файл не подтверждён на живом железе. "
            "Сначала снимите его sha256 и впишите в station/models.py.")
    assets_dir = pathlib.Path(assets_dir)
    path = assets_dir / spec.name
    if not path.exists():
        raise ArtifactError(
            f"Нет файла {spec.name}. Положите его в {assets_dir} "
            f"(ожидается размер {spec.size} байт).")
    actual = path.stat().st_size
    if actual != spec.size:
        raise ArtifactError(f"{spec.name}: размер {actual} вместо {spec.size}")
    got = sha256_file(path)
    if got != spec.sha256:
        raise ArtifactError(
            f"{spec.name}: сумма {got} не совпала с ожидаемой {spec.sha256}")
    return path
```

- [ ] **Step 4: Запустить, убедиться что проходит**

Run: `python -m pytest station/tests/test_thirdparty.py -v`
Expected: PASS (4 passed)

- [ ] **Step 5: Коммит**

```bash
git add station/thirdparty.py station/tests/test_thirdparty.py
git commit -m "feat(station): сторонние файлы по закреплённым суммам"
```

---

### Task 5: Граница Remote с раздельными потоками

**Files:**
- Create: `station/remote.py`
- Test: `station/tests/test_remote.py`

**Interfaces:**
- Produces:
  - `@dataclass(frozen=True) Result(code: int, stdout: bytes, stderr: bytes)` со свойством `text` (stdout как строка)
  - `class Remote(Protocol)`: `run(cmd) -> Result`, `upload(data, dest) -> None`, `read(path, size=None) -> bytes`, `reboot() -> None`
  - `class FakeRemote` — для тестов: `files`, `responses`, `uploaded`, `commands`, `rebooted: int`

Раздельные `stdout` и `stderr` — не косметика: при склейке любая строка предупреждения ядра попадает внутрь образа раздела, и «годная» копия Factory оказывается мусором.

- [ ] **Step 1: Написать падающий тест**

```python
# station/tests/test_remote.py
from station.remote import FakeRemote, Result

def test_result_keeps_streams_apart():
    r = Result(0, b"data", b"warning: ecc")
    assert r.stdout == b"data" and r.stderr == b"warning: ecc"
    assert r.text == "data"

def test_fake_records_commands_uploads_and_reboots():
    f = FakeRemote(files={"/dev/mtd0": b"body"},
                   responses={"uname -a": Result(0, b"Linux", b"")})
    assert f.run("uname -a").stdout == b"Linux"
    assert f.run("unknown").code == 0
    f.upload(b"payload", "/tmp/x")
    f.reboot()
    assert f.uploaded["/tmp/x"] == b"payload"
    assert f.commands == ["uname -a", "unknown"]
    assert f.rebooted == 1

def test_fake_read_with_zero_size_returns_nothing():
    f = FakeRemote(files={"/dev/mtd0": b"body"})
    assert f.read("/dev/mtd0", 0) == b""
    assert f.read("/dev/mtd0") == b"body"
    assert f.read("/dev/mtd0", 2) == b"bo"
```

- [ ] **Step 2: Запустить, убедиться что падает**

Run: `python -m pytest station/tests/test_remote.py -v`
Expected: FAIL, `ModuleNotFoundError`

- [ ] **Step 3: Написать модуль**

```python
# station/remote.py
from dataclasses import dataclass, field
from typing import Protocol

@dataclass(frozen=True)
class Result:
    code: int
    stdout: bytes
    stderr: bytes

    @property
    def text(self) -> str:
        return self.stdout.decode("utf-8", "replace")

class Remote(Protocol):
    def run(self, cmd: str) -> Result: ...
    def upload(self, data: bytes, dest: str) -> None: ...
    def read(self, path: str, size: int | None = None) -> bytes: ...
    def reboot(self) -> None: ...

class FakeRemote:
    def __init__(self, files=None, responses=None):
        self.files = dict(files or {})
        self.responses = dict(responses or {})
        self.uploaded: dict[str, bytes] = {}
        self.commands: list[str] = []
        self.rebooted = 0

    def run(self, cmd: str) -> Result:
        self.commands.append(cmd)
        return self.responses.get(cmd, Result(0, b"", b""))

    def upload(self, data: bytes, dest: str) -> None:
        self.uploaded[dest] = data

    def read(self, path: str, size: int | None = None) -> bytes:
        data = self.files[path]
        return data if size is None else data[:size]

    def reboot(self) -> None:
        self.rebooted += 1
```

- [ ] **Step 4: Запустить, убедиться что проходит**

Run: `python -m pytest station/tests/test_remote.py -v`
Expected: PASS (3 passed)

- [ ] **Step 5: Коммит**

```bash
git add station/remote.py station/tests/test_remote.py
git commit -m "feat(station): граница Remote с раздельными stdout и stderr"
```

---

### Task 6: Разбор /proc/mtd и обязательные разделы

**Files:**
- Create: `station/mtd.py`
- Test: `station/tests/test_mtd.py`

**Interfaces:**
- Consumes: `Remote`, `Result`
- Produces:
  - `@dataclass(frozen=True) Partition(dev: str, name: str, size: int)`
  - `class MtdError(Exception)`
  - `parse_proc_mtd(text) -> list[Partition]`
  - `find_partition(parts, name) -> Partition`
  - `read_partitions(remote) -> list[Partition]`
  - `require_partitions(parts, names) -> None` — `MtdError`, если чего-то нет

- [ ] **Step 1: Написать падающий тест**

```python
# station/tests/test_mtd.py
import pytest
from station.remote import FakeRemote, Result
from station.mtd import (parse_proc_mtd, find_partition, read_partitions,
                         require_partitions, MtdError)

SAMPLE = ('dev:    size   erasesize  name\n'
          'mtd0: 00100000 00020000 "BL2"\n'
          'mtd1: 00040000 00020000 "u-boot-env"\n'
          'mtd3: 00080000 00020000 "Factory"\n'
          'mtd4: 00080000 00020000 "FIP"\n'
          'mtd5: 07800000 00020000 "ubi"\n')

def test_parse_lists_all_partitions():
    parts = parse_proc_mtd(SAMPLE)
    assert [p.name for p in parts] == ["BL2", "u-boot-env", "Factory", "FIP", "ubi"]
    assert find_partition(parts, "ubi").dev == "/dev/mtd5"
    assert find_partition(parts, "FIP").size == 0x80000

def test_missing_partition_raises():
    with pytest.raises(KeyError):
        find_partition(parse_proc_mtd(SAMPLE), "rootfs")

def test_read_partitions_uses_stdout_only():
    r = FakeRemote(responses={"cat /proc/mtd": Result(0, SAMPLE.encode(), b"noise")})
    assert len(read_partitions(r)) == 5

def test_read_partitions_fails_on_nonzero_code():
    r = FakeRemote(responses={"cat /proc/mtd": Result(1, b"", b"denied")})
    with pytest.raises(MtdError):
        read_partitions(r)

def test_require_partitions_names_what_is_missing():
    parts = parse_proc_mtd(SAMPLE)
    require_partitions(parts, ("Factory", "BL2", "FIP", "ubi"))  # не бросает
    with pytest.raises(MtdError) as e:
        require_partitions(parts, ("Factory", "art"))
    assert "art" in str(e.value)
```

- [ ] **Step 2: Запустить, убедиться что падает**

Run: `python -m pytest station/tests/test_mtd.py -v`
Expected: FAIL, `ModuleNotFoundError`

- [ ] **Step 3: Написать модуль**

```python
# station/mtd.py
import re
from dataclasses import dataclass

@dataclass(frozen=True)
class Partition:
    dev: str
    name: str
    size: int

class MtdError(Exception):
    pass

_LINE = re.compile(r'^(mtd\d+):\s+([0-9a-fA-F]+)\s+[0-9a-fA-F]+\s+"([^"]*)"')

def parse_proc_mtd(text: str) -> list[Partition]:
    parts = []
    for line in text.splitlines():
        m = _LINE.match(line.strip())
        if m:
            parts.append(Partition(f"/dev/{m.group(1)}", m.group(3),
                                   int(m.group(2), 16)))
    return parts

def find_partition(parts, name: str) -> Partition:
    for p in parts:
        if p.name == name:
            return p
    raise KeyError(name)

def read_partitions(remote) -> list[Partition]:
    res = remote.run("cat /proc/mtd")
    if res.code != 0:
        raise MtdError(f"не удалось прочитать /proc/mtd: "
                       f"{res.stderr.decode('utf-8', 'replace')}")
    return parse_proc_mtd(res.text)

def require_partitions(parts, names) -> None:
    have = {p.name for p in parts}
    missing = [n for n in names if n not in have]
    if missing:
        raise MtdError(
            "На роутере нет обязательных разделов: " + ", ".join(missing) +
            ". Найдены: " + ", ".join(sorted(have)))
```

- [ ] **Step 4: Запустить, убедиться что проходит**

Run: `python -m pytest station/tests/test_mtd.py -v`
Expected: PASS (5 passed)

- [ ] **Step 5: Коммит**

```bash
git add station/mtd.py station/tests/test_mtd.py
git commit -m "feat(station): разбор /proc/mtd и проверка обязательных разделов"
```

---

### Task 7: Копии разделов с двойным чтением

**Files:**
- Modify: `station/mtd.py`
- Test: `station/tests/test_mtd_backup.py`

**Interfaces:**
- Consumes: `Remote`, `Partition`, `read_partitions`, `MtdError`
- Produces:
  - `backup_partition(remote, part, dest_dir) -> pathlib.Path` — читает раздел дважды, при расхождении `MtdError`
  - `backup_all(remote, parts, dest_dir, required, skip=("ubi",)) -> dict[str, pathlib.Path]` — после копирования проверяет, что все `required` (кроме пропущенных) действительно сохранены; иначе `MtdError`

Копия `Factory` — единственная страховка от кирпича: в нём калибровка Wi-Fi и
MAC-адреса, взять их больше неоткуда. Поэтому её отсутствие обязано
останавливать работу, а не проходить молча.

- [ ] **Step 1: Написать падающий тест**

```python
# station/tests/test_mtd_backup.py
import pytest
from station.remote import FakeRemote, Result
from station.mtd import (read_partitions, backup_partition, backup_all,
                         find_partition, MtdError)

PROC = Result(0, (b'dev:    size   erasesize  name\n'
                  b'mtd0: 00100000 00020000 "BL2"\n'
                  b'mtd3: 00080000 00020000 "Factory"\n'
                  b'mtd5: 07800000 00020000 "ubi"\n'), b"")

REQUIRED = ("Factory", "BL2")

def _remote(files=None):
    return FakeRemote(responses={"cat /proc/mtd": PROC}, files=files or {})

def test_backup_ok_when_two_reads_match(tmp_path):
    r = _remote({"/dev/mtd3": b"factory-bytes"})
    part = find_partition(read_partitions(r), "Factory")
    assert backup_partition(r, part, tmp_path).read_bytes() == b"factory-bytes"

def test_backup_fails_when_reads_differ(tmp_path):
    class Flaky(FakeRemote):
        def __init__(self):
            super().__init__(responses={"cat /proc/mtd": PROC})
            self._n = 0
        def read(self, path, size=None):
            self._n += 1
            return b"first" if self._n == 1 else b"second"
    r = Flaky()
    part = find_partition(read_partitions(r), "Factory")
    with pytest.raises(MtdError) as e:
        backup_partition(r, part, tmp_path)
    assert "Factory" in str(e.value)

def test_backup_all_skips_ubi_and_keeps_the_rest(tmp_path):
    r = _remote({"/dev/mtd0": b"bl2", "/dev/mtd3": b"fac", "/dev/mtd5": b"ubi"})
    got = backup_all(r, read_partitions(r), tmp_path, REQUIRED)
    assert set(got) == {"BL2", "Factory"}

def test_backup_all_refuses_when_required_partition_absent(tmp_path):
    proc_without_factory = Result(0, (b'dev:    size   erasesize  name\n'
                                      b'mtd0: 00100000 00020000 "BL2"\n'), b"")
    r = FakeRemote(responses={"cat /proc/mtd": proc_without_factory},
                   files={"/dev/mtd0": b"bl2"})
    with pytest.raises(MtdError) as e:
        backup_all(r, read_partitions(r), tmp_path, REQUIRED)
    assert "Factory" in str(e.value)
```

- [ ] **Step 2: Запустить, убедиться что падает**

Run: `python -m pytest station/tests/test_mtd_backup.py -v`
Expected: FAIL, `ImportError: cannot import name 'backup_partition'`

- [ ] **Step 3: Дописать в `station/mtd.py`**

Добавить `import pathlib` к импортам в начале файла, затем в конец:

```python
def backup_partition(remote, part: Partition, dest_dir) -> "pathlib.Path":
    first = remote.read(part.dev)
    second = remote.read(part.dev)
    if first != second:
        raise MtdError(
            f"{part.name}: два чтения раздела не совпали "
            f"({len(first)} и {len(second)} байт). Копия негодна.")
    dest_dir = pathlib.Path(dest_dir)
    dest_dir.mkdir(parents=True, exist_ok=True)
    dest = dest_dir / f"{part.name}.bin"
    dest.write_bytes(first)
    return dest

def backup_all(remote, parts, dest_dir, required, skip=("ubi",)) -> dict:
    out = {}
    for p in parts:
        if p.name in skip:
            continue
        out[p.name] = backup_partition(remote, p, dest_dir)
    missing = [n for n in required if n not in out and n not in skip]
    if missing:
        raise MtdError(
            "Не сняты копии обязательных разделов: " + ", ".join(missing) +
            ". Без них восстановление после неудачной записи невозможно.")
    return out
```

- [ ] **Step 4: Запустить, убедиться что проходит**

Run: `python -m pytest station/tests/test_mtd_backup.py -v`
Expected: PASS (4 passed)

- [ ] **Step 5: Коммит**

```bash
git add station/mtd.py station/tests/test_mtd_backup.py
git commit -m "feat(station): копии разделов с двойным чтением, Factory обязателен"
```

---

### Task 8: Запись загрузчика

**Files:**
- Modify: `station/mtd.py`
- Test: `station/tests/test_mtd_write.py`

**Interfaces:**
- Consumes: `Remote`, `Partition`, `MtdError`, `sha256_file`
- Produces:
  - `upload_and_verify(remote, local_path, dest) -> None` — заливает файл и сверяет sha256 **на роутере**
  - `insmod_mtd_rw(remote, local_ko) -> None` — заливает модуль и загружает его
  - `write_and_verify(remote, part, local_path) -> None` — проверяет, что файл помещается в раздел; заливает и сверяет; пишет; читает записанное обратно и сравнивает

Три проверки вокруг единственного необратимого шага: файл не больше раздела,
сумма совпала уже на роутере, записанное прочиталось обратно. Перезагрузка
происходит позже и только если все три прошли.

- [ ] **Step 1: Написать падающий тест**

```python
# station/tests/test_mtd_write.py
import hashlib, pytest
from station.remote import FakeRemote, Result
from station.mtd import (Partition, write_and_verify, upload_and_verify,
                         insmod_mtd_rw, MtdError)

def _ok_remote(dev, body, tmp_name="fip.bin"):
    digest = hashlib.sha256(body).hexdigest()
    return FakeRemote(
        responses={
            f"sha256sum /tmp/{tmp_name}": Result(0, f"{digest}  /tmp/{tmp_name}\n".encode(), b""),
            "mtd write /tmp/fip.bin FIP": Result(0, b"", b""),
        },
        files={dev: body})

def test_write_ok_when_readback_matches(tmp_path):
    body = b"fip-image-body"
    f = tmp_path / "fip.bin"; f.write_bytes(body)
    part = Partition("/dev/mtd4", "FIP", 0x80000)
    r = _ok_remote("/dev/mtd4", body)
    write_and_verify(r, part, f)
    assert r.uploaded["/tmp/fip.bin"] == body

def test_write_refuses_file_larger_than_partition(tmp_path):
    body = b"x" * 100
    f = tmp_path / "fip.bin"; f.write_bytes(body)
    part = Partition("/dev/mtd4", "FIP", 50)      # раздел меньше файла
    r = _ok_remote("/dev/mtd4", body)
    with pytest.raises(MtdError) as e:
        write_and_verify(r, part, f)
    assert "не помещается" in str(e.value)
    assert r.commands == []                        # ничего не писали

def test_write_fails_on_hash_mismatch_on_router(tmp_path):
    body = b"fip-image-body"
    f = tmp_path / "fip.bin"; f.write_bytes(body)
    part = Partition("/dev/mtd4", "FIP", 0x80000)
    r = _ok_remote("/dev/mtd4", body)
    r.responses["sha256sum /tmp/fip.bin"] = Result(0, b"deadbeef  /tmp/fip.bin\n", b"")
    with pytest.raises(MtdError):
        write_and_verify(r, part, f)

def test_write_fails_when_readback_differs(tmp_path):
    body = b"fip-image-body"
    f = tmp_path / "fip.bin"; f.write_bytes(body)
    part = Partition("/dev/mtd4", "FIP", 0x80000)
    r = _ok_remote("/dev/mtd4", body)
    r.files["/dev/mtd4"] = b"something-else!"
    with pytest.raises(MtdError) as e:
        write_and_verify(r, part, f)
    assert "обратное чтение" in str(e.value)

def test_insmod_uploads_module_first(tmp_path):
    body = b"module"
    ko = tmp_path / "mtd-rw.ko"; ko.write_bytes(body)
    digest = hashlib.sha256(body).hexdigest()
    r = FakeRemote(responses={
        "grep -q '^mtd_rw ' /proc/modules": Result(1, b"", b""),
        "sha256sum /tmp/mtd-rw.ko": Result(0, f"{digest}  /tmp/mtd-rw.ko\n".encode(), b""),
        "insmod /tmp/mtd-rw.ko i_want_a_brick=1": Result(0, b"", b""),
    })
    insmod_mtd_rw(r, ko)
    assert r.uploaded["/tmp/mtd-rw.ko"] == body

def test_insmod_is_idempotent_when_already_loaded(tmp_path):
    # обработчик вызывает загрузку дважды — перед FIP и перед BL2;
    # второй insmod на живом роутере упал бы с "File exists"
    ko = tmp_path / "mtd-rw.ko"; ko.write_bytes(b"module")
    r = FakeRemote(responses={"grep -q '^mtd_rw ' /proc/modules": Result(0, b"", b"")})
    insmod_mtd_rw(r, ko)
    assert r.uploaded == {}
    assert r.commands == ["grep -q '^mtd_rw ' /proc/modules"]

def test_insmod_fails_loudly(tmp_path):
    body = b"module"
    ko = tmp_path / "mtd-rw.ko"; ko.write_bytes(body)
    digest = hashlib.sha256(body).hexdigest()
    r = FakeRemote(responses={
        "grep -q '^mtd_rw ' /proc/modules": Result(1, b"", b""),
        "sha256sum /tmp/mtd-rw.ko": Result(0, f"{digest}  /tmp/mtd-rw.ko\n".encode(), b""),
        "insmod /tmp/mtd-rw.ko i_want_a_brick=1": Result(1, b"", b"invalid module format"),
    })
    with pytest.raises(MtdError) as e:
        insmod_mtd_rw(r, ko)
    assert "invalid module format" in str(e.value)
```

- [ ] **Step 2: Запустить, убедиться что падает**

Run: `python -m pytest station/tests/test_mtd_write.py -v`
Expected: FAIL, `ImportError: cannot import name 'write_and_verify'`

- [ ] **Step 3: Дописать в `station/mtd.py`**

Добавить в начало файла `from .artifacts import sha256_file`, затем в конец:

```python
def upload_and_verify(remote, local_path, dest: str) -> None:
    local_path = pathlib.Path(local_path)
    data = local_path.read_bytes()
    remote.upload(data, dest)
    want = sha256_file(local_path)
    res = remote.run(f"sha256sum {dest}")
    got = res.text.split()[0] if res.code == 0 and res.text.split() else ""
    if got != want:
        raise MtdError(
            f"{dest}: сумма на роутере {got or 'не получена'} не совпала с {want}")

def insmod_mtd_rw(remote, local_ko) -> None:
    # Вызывается дважды: перед записью FIP и перед записью BL2. Между ними
    # роутер не перезагружается, поэтому второй раз модуль уже загружен и
    # insmod упал бы с "File exists".
    if remote.run("grep -q '^mtd_rw ' /proc/modules").code == 0:
        return
    upload_and_verify(remote, local_ko, "/tmp/mtd-rw.ko")
    res = remote.run("insmod /tmp/mtd-rw.ko i_want_a_brick=1")
    if res.code != 0:
        raise MtdError("insmod mtd-rw не удался: "
                       + res.stderr.decode("utf-8", "replace").strip())

def write_and_verify(remote, part: Partition, local_path) -> None:
    local_path = pathlib.Path(local_path)
    data = local_path.read_bytes()
    if len(data) > part.size:
        raise MtdError(
            f"{local_path.name} ({len(data)} байт) не помещается в раздел "
            f"{part.name} ({part.size} байт). Запись не начата.")

    dest = f"/tmp/{local_path.name}"
    upload_and_verify(remote, local_path, dest)

    res = remote.run(f"mtd write {dest} {part.name}")
    if res.code != 0:
        raise MtdError(f"mtd write {part.name}: "
                       + res.stderr.decode("utf-8", "replace").strip())

    back = remote.read(part.dev, len(data))
    if back != data:
        raise MtdError(
            f"{part.name}: обратное чтение не совпало с записанным. "
            f"НЕ перезагружайте роутер — повторите запись.")
```

- [ ] **Step 4: Запустить, убедиться что проходит**

Run: `python -m pytest station/tests/test_mtd_write.py -v`
Expected: PASS (7 passed)

- [ ] **Step 5: Коммит**

```bash
git add station/mtd.py station/tests/test_mtd_write.py
git commit -m "feat(station): запись загрузчика с тремя проверками до перезагрузки"
```

---

### Task 9: Сервер TFTP только на чтение

**Files:**
- Create: `station/tftp.py`
- Test: `station/tests/test_tftp.py`

**Interfaces:**
- Produces:
  - `class TftpError(Exception)`
  - `parse_rrq(packet) -> tuple[str, str]`
  - `split_blocks(data: bytes) -> list[bytes]` — разбивка по 512 с завершающим коротким блоком
  - `class ReadOnlyTftp(filename, data, host, port)` — `start()`, `stop()`, `served: bool`, `requests: list[str]` (все запрошенные имена, включая отвергнутые)

Разбивка вынесена отдельной функцией, потому что в ней ровно та ошибка, из-за
которой образ кратной длины передаётся, а успех не фиксируется.

- [ ] **Step 1: Написать падающий тест**

```python
# station/tests/test_tftp.py
import socket, struct, pytest
from station.tftp import ReadOnlyTftp, parse_rrq, split_blocks, TftpError

def test_parse_rrq():
    assert parse_rrq(b"\x00\x01" + b"file.itb\x00octet\x00") == ("file.itb", "octet")

def test_parse_rejects_wrq():
    with pytest.raises(TftpError):
        parse_rrq(b"\x00\x02file\x00octet\x00")

def test_split_blocks_adds_terminator_for_exact_multiple():
    assert split_blocks(b"") == [b""]
    assert [len(b) for b in split_blocks(b"A" * 512)] == [512, 0]
    assert [len(b) for b in split_blocks(b"A" * 1024)] == [512, 512, 0]
    assert [len(b) for b in split_blocks(b"A" * 1100)] == [512, 512, 76]

def _fetch(port, name):
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM); s.settimeout(3)
    s.sendto(b"\x00\x01" + name.encode() + b"\x00octet\x00", ("127.0.0.1", port))
    got = b""
    try:
        while True:
            data, addr = s.recvfrom(1024)
            if struct.unpack("!H", data[:2])[0] == 5:
                raise AssertionError("tftp error")
            blk = struct.unpack("!H", data[2:4])[0]
            got += data[4:]
            s.sendto(b"\x00\x04" + struct.pack("!H", blk), addr)
            if len(data[4:]) < 512:
                return got
    finally:
        s.close()

@pytest.mark.parametrize("size", [0, 511, 512, 1024, 1100])
def test_serves_any_size_and_marks_served(size):
    body = b"A" * size
    srv = ReadOnlyTftp("recovery.itb", body, host="127.0.0.1", port=0)
    srv.start()
    try:
        assert _fetch(srv.port, "recovery.itb") == body
        assert srv.served is True, f"размер {size}: передача прошла, успех не отмечен"
    finally:
        srv.stop()

def test_refuses_other_name_but_records_it():
    srv = ReadOnlyTftp("recovery.itb", b"x", host="127.0.0.1", port=0)
    srv.start()
    try:
        with pytest.raises(AssertionError):
            _fetch(srv.port, "other.itb")
        assert "other.itb" in srv.requests
    finally:
        srv.stop()
```

- [ ] **Step 2: Запустить, убедиться что падает**

Run: `python -m pytest station/tests/test_tftp.py -v`
Expected: FAIL, `ModuleNotFoundError`

- [ ] **Step 3: Написать модуль**

```python
# station/tftp.py
import socket, struct, threading

class TftpError(Exception):
    pass

def parse_rrq(packet: bytes) -> tuple[str, str]:
    if packet[:2] != b"\x00\x01":
        raise TftpError("не RRQ")
    parts = packet[2:].split(b"\x00")
    if len(parts) < 2:
        raise TftpError("повреждённый RRQ")
    return parts[0].decode("latin1"), parts[1].decode("latin1").lower()

def split_blocks(data: bytes) -> list[bytes]:
    blocks = [data[i:i + 512] for i in range(0, len(data), 512)]
    if not blocks or len(blocks[-1]) == 512:
        blocks.append(b"")
    return blocks

class ReadOnlyTftp:
    def __init__(self, filename: str, data: bytes, host: str = "192.168.1.254",
                 port: int = 69):
        self.filename = filename
        self.data = data
        self.host = host
        self._want_port = port
        self.port = port
        self.served = False
        self.requests: list[str] = []
        self._sock = None
        self._thread = None
        self._stop = threading.Event()

    def start(self) -> None:
        self._sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        self._sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        self._sock.bind((self.host, self._want_port))
        self.port = self._sock.getsockname()[1]
        self._sock.settimeout(0.5)
        self._thread = threading.Thread(target=self._run, daemon=True)
        self._thread.start()

    def stop(self) -> None:
        self._stop.set()
        if self._thread:
            self._thread.join(timeout=5)
        if self._sock:
            self._sock.close()

    def _error(self, addr, message: str) -> None:
        self._sock.sendto(b"\x00\x05\x00\x00" + message.encode() + b"\x00", addr)

    def _run(self) -> None:
        while not self._stop.is_set():
            try:
                packet, addr = self._sock.recvfrom(1024)
            except socket.timeout:
                continue
            except OSError:
                return
            if packet[:2] == b"\x00\x02":
                self.requests.append("(запись отвергнута)")
                self._error(addr, "read-only")
                continue
            try:
                name, mode = parse_rrq(packet)
            except TftpError:
                continue
            self.requests.append(name)
            if name != self.filename or mode != "octet":
                self._error(addr, "not found")
                continue
            self._send(addr)

    def _send(self, addr) -> None:
        for number, chunk in enumerate(split_blocks(self.data), start=1):
            packet = b"\x00\x03" + struct.pack("!H", number & 0xFFFF) + chunk
            for _ in range(5):
                if self._stop.is_set():
                    return
                self._sock.sendto(packet, addr)
                try:
                    ack, _ = self._sock.recvfrom(1024)
                except socket.timeout:
                    continue
                except OSError:
                    return
                if (ack[:2] == b"\x00\x04"
                        and struct.unpack("!H", ack[2:4])[0] == (number & 0xFFFF)):
                    break
            else:
                return
        self.served = True
```

- [ ] **Step 4: Запустить, убедиться что проходит**

Run: `python -m pytest station/tests/test_tftp.py -v`
Expected: PASS (9 passed — три обычных теста и пять из параметризованного)

- [ ] **Step 5: Коммит**

```bash
git add station/tftp.py station/tests/test_tftp.py
git commit -m "feat(station): TFTP только на чтение, верная разбивка на блоки"
```

---

### Task 10: Проверка прав на порт 69

**Files:**
- Create: `station/privileges.py`
- Test: `station/tests/test_privileges.py`

**Interfaces:**
- Produces:
  - `can_bind_udp(host: str, port: int) -> bool`
  - `privilege_hint(os_name: str, port: int = 69) -> str`
  - `class PrivilegeError(Exception)`
  - `require_tftp_port(os_name, host, port=69) -> None` — бросает `PrivilegeError` с подсказкой

Проверка стоит **до** записи загрузчика. Обнаружить нехватку прав после того,
как роутер уже перезагружен в восстановление, значит оставить его лежать.

- [ ] **Step 1: Написать падающий тест**

```python
# station/tests/test_privileges.py
import pytest
from station.privileges import (can_bind_udp, privilege_hint, require_tftp_port,
                                PrivilegeError)

def test_high_port_is_bindable():
    assert can_bind_udp("127.0.0.1", 0) is True

def test_hint_mentions_platform_specific_fix():
    assert "sudo" in privilege_hint("linux")
    assert "sudo" in privilege_hint("darwin")
    assert "Администратор" in privilege_hint("windows")

def test_require_raises_with_hint_when_not_bindable(monkeypatch):
    monkeypatch.setattr("station.privileges.can_bind_udp", lambda h, p: False)
    with pytest.raises(PrivilegeError) as e:
        require_tftp_port("linux", "127.0.0.1", 69)
    assert "sudo" in str(e.value)

def test_require_passes_when_bindable(monkeypatch):
    monkeypatch.setattr("station.privileges.can_bind_udp", lambda h, p: True)
    require_tftp_port("linux", "127.0.0.1", 69)
```

- [ ] **Step 2: Запустить, убедиться что падает**

Run: `python -m pytest station/tests/test_privileges.py -v`
Expected: FAIL, `ModuleNotFoundError`

- [ ] **Step 3: Написать модуль**

```python
# station/privileges.py
import socket

class PrivilegeError(Exception):
    pass

def can_bind_udp(host: str, port: int) -> bool:
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    try:
        s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        s.bind((host, port))
        return True
    except OSError:
        return False
    finally:
        s.close()

def privilege_hint(os_name: str, port: int = 69) -> str:
    o = os_name.lower()
    if o.startswith("win"):
        return (f"Запустите станцию от имени Администратора и разрешите "
                f"входящий UDP {port} в брандмауэре Windows.")
    if o.startswith("darwin") or o == "mac":
        return f"Запустите станцию через sudo: порт {port} привилегированный."
    return (f"Запустите станцию через sudo либо выдайте право один раз: "
            f"sudo setcap 'cap_net_bind_service=+ep' $(readlink -f $(which python3))")

def require_tftp_port(os_name: str, host: str, port: int = 69) -> None:
    if not can_bind_udp(host, port):
        raise PrivilegeError(
            f"Не удалось занять UDP {host}:{port} — без него роутер не получит "
            f"образ восстановления. " + privilege_hint(os_name, port))
```

- [ ] **Step 4: Запустить, убедиться что проходит**

Run: `python -m pytest station/tests/test_privileges.py -v`
Expected: PASS (4 passed)

- [ ] **Step 5: Коммит**

```bash
git add station/privileges.py station/tests/test_privileges.py
git commit -m "feat(station): проверка прав на порт 69 до записи загрузчика"
```

---

### Task 11: Сеть на выбранном интерфейсе

**Files:**
- Create: `station/network.py`
- Test: `station/tests/test_network.py`

**Interfaces:**
- Produces:
  - `interface_command(os_name, iface) -> list[str]` — команда, показывающая адреса **только** этого интерфейса
  - `parse_addresses(os_name, output) -> set[str]`
  - `check_ready(addresses) -> list[str]`
  - `setup_command(os_name, iface) -> str`
  - `looks_wireless(iface: str) -> bool`

Разбор привязан к интерфейсу через саму команду: адрес `192.168.10.x`, висящий
на Wi-Fi или на мосте виртуальной машины, не должен считаться готовностью.

- [ ] **Step 1: Написать падающий тест**

```python
# station/tests/test_network.py
from station.network import (interface_command, parse_addresses, check_ready,
                             setup_command, looks_wireless)

LINUX = ("2: eth0: <BROADCAST,MULTICAST,UP> mtu 1500\n"
         "    inet 192.168.10.5/24 brd 192.168.10.255 scope global eth0\n"
         "    inet 192.168.1.254/24 scope global secondary eth0\n")
MAC = ("en0: flags=8863<UP,BROADCAST,SMART,RUNNING> mtu 1500\n"
       "\tinet 192.168.10.5 netmask 0xffffff00 broadcast 192.168.10.255\n"
       "\tinet 192.168.1.254 netmask 0xffffff00\n")
WIN = ("Configuration for interface \"Ethernet\"\n"
       "    IP Address:                           192.168.10.7\n"
       "    Subnet Prefix:                        192.168.10.0/24\n")

def test_command_is_scoped_to_interface():
    assert "eth0" in " ".join(interface_command("linux", "eth0"))
    assert "en0" in " ".join(interface_command("darwin", "en0"))
    assert "Ethernet" in " ".join(interface_command("windows", "Ethernet"))

def test_parse_three_formats():
    assert {"192.168.10.5", "192.168.1.254"} <= parse_addresses("linux", LINUX)
    assert {"192.168.10.5", "192.168.1.254"} <= parse_addresses("darwin", MAC)
    assert "192.168.10.7" in parse_addresses("windows", WIN)

def test_parse_ignores_masks_and_broadcasts():
    got = parse_addresses("darwin", MAC)
    assert "255.255.255.0" not in got
    assert "192.168.10.255" not in got

def test_check_ready_reports_what_is_missing():
    missing = check_ready({"192.168.10.5"})
    assert any("192.168.1.254" in m for m in missing)
    assert check_ready({"192.168.10.5", "192.168.1.254"}) == []

def test_setup_command_mentions_iface_and_address():
    cmd = setup_command("linux", "eth0")
    assert "eth0" in cmd and "192.168.1.254" in cmd

def test_wireless_names_are_flagged():
    assert looks_wireless("wlan0") and looks_wireless("Wi-Fi") and looks_wireless("en1-wifi")
    assert not looks_wireless("eth0") and not looks_wireless("Ethernet")
```

- [ ] **Step 2: Запустить, убедиться что падает**

Run: `python -m pytest station/tests/test_network.py -v`
Expected: FAIL, `ModuleNotFoundError`

- [ ] **Step 3: Написать модуль**

```python
# station/network.py
import ipaddress, re

_IPV4 = re.compile(r'(?<![\d.])(\d{1,3}(?:\.\d{1,3}){3})(?![\d.])')
_WIRELESS = ("wlan", "wifi", "wi-fi", "wl", "airport", "беспровод")

def interface_command(os_name: str, iface: str) -> list[str]:
    o = os_name.lower()
    if o.startswith("win"):
        return ["netsh", "interface", "ip", "show", "addresses", f"name={iface}"]
    if o.startswith("darwin") or o == "mac":
        return ["ifconfig", iface]
    return ["ip", "-4", "addr", "show", "dev", iface]

def parse_addresses(os_name: str, output: str) -> set[str]:
    found = set()
    for line in output.splitlines():
        low = line.lower()
        if "broadcast" in low and "inet " not in low:
            continue
        for m in _IPV4.finditer(line):
            value = m.group(1)
            try:
                addr = ipaddress.IPv4Address(value)
            except ValueError:
                continue
            if addr.is_loopback or addr.is_multicast:
                continue
            if value.startswith("255.") or value.endswith(".255"):
                continue
            found.add(value)
    return found

def check_ready(addresses: set[str]) -> list[str]:
    missing = []
    net = ipaddress.ip_network("192.168.10.0/24")
    if not any(ipaddress.IPv4Address(a) in net for a in addresses):
        missing.append("на интерфейсе нет адреса из 192.168.10.0/24 — "
                       "без него не войти в заводской роутер")
    if "192.168.1.254" not in addresses:
        missing.append("на интерфейсе нет адреса 192.168.1.254 — "
                       "его ждёт загрузчик при восстановлении по TFTP")
    return missing

def setup_command(os_name: str, iface: str) -> str:
    o = os_name.lower()
    if o.startswith("darwin") or o == "mac":
        return f"sudo ifconfig {iface} alias 192.168.1.254 255.255.255.0"
    if o.startswith("win"):
        return (f'netsh interface ip add address name="{iface}" '
                f'addr=192.168.1.254 mask=255.255.255.0')
    return f"sudo ip addr add 192.168.1.254/24 dev {iface}"

def looks_wireless(iface: str) -> bool:
    low = iface.lower()
    return any(token in low for token in _WIRELESS)
```

- [ ] **Step 4: Запустить, убедиться что проходит**

Run: `python -m pytest station/tests/test_network.py -v`
Expected: PASS (6 passed)

- [ ] **Step 5: Коммит**

```bash
git add station/network.py station/tests/test_network.py
git commit -m "feat(station): адреса проверяются на выбранном интерфейсе"
```

---

### Task 12: Команды роутера и приёмка

**Files:**
- Create: `station/commands.py`
- Test: `station/tests/test_commands.py`

**Interfaces:**
- Produces:
  - `ubi_layout_commands(ubi_dev) -> list[str]`
  - `sysupgrade_command(remote_path) -> str`
  - `df_command() -> str`, `board_command() -> str`
  - `free_space_kb(df_output) -> int`
  - `parse_board(json_text) -> tuple[str, str]` — `(board_name, release_version)`
  - `acceptance_problems(board, version, free_kb, *, want_board, want_version, min_kb=40*1024) -> list[str]`

`want_board` — это `board_ubus`, то есть **через запятую**. Тест подаёт запятую
с одной стороны и подчёркивание с другой, чтобы поймать именно ту ошибку,
из-за которой приёмка отказывала бы на каждом исправном роутере.

- [ ] **Step 1: Написать падающий тест**

```python
# station/tests/test_commands.py
import pytest
from station.commands import (ubi_layout_commands, sysupgrade_command, df_command,
                              board_command, free_space_kb, parse_board,
                              acceptance_problems)

def test_ubi_layout_uses_named_device():
    joined = " ".join(ubi_layout_commands("/dev/mtd5"))
    assert "ubiformat /dev/mtd5 -y" in joined
    assert "ubootenv" in joined and "ubootenv2" in joined

def test_sysupgrade_does_not_preserve_settings():
    assert sysupgrade_command("/tmp/sysupgrade.itb") == "sysupgrade -n /tmp/sysupgrade.itb"

def test_df_command_is_portable():
    assert df_command() == "df -Pk /overlay"

def test_free_space_parsing_posix_format():
    df = ("Filesystem     1024-blocks  Used Available Capacity Mounted on\n"
          "overlayfs:/overlay  102400  1024    101376       1% /overlay\n")
    assert free_space_kb(df) == 101376

def test_free_space_rejects_similar_mountpoint():
    df = ("Filesystem     1024-blocks  Used Available Capacity Mounted on\n"
          "tmpfs               10240   100     10140       1% /tmp/overlay\n")
    with pytest.raises(ValueError):
        free_space_kb(df)

def test_parse_board_reads_comma_form():
    board, version = parse_board(
        '{"board_name":"cudy,wbr3000uax-v1","release":{"version":"25.12.4"}}')
    assert board == "cudy,wbr3000uax-v1"
    assert version == "25.12.4"

def test_acceptance_catches_comma_underscore_confusion():
    problems = acceptance_problems("cudy,wbr3000uax-v1", "25.12.4", 60000,
                                   want_board="cudy_wbr3000uax-v1",
                                   want_version="25.12.4")
    assert problems, "подчёркивание вместо запятой обязано быть замечено"

def test_acceptance_passes_on_correct_router():
    assert acceptance_problems("cudy,wbr3000uax-v1", "25.12.4", 60000,
                               want_board="cudy,wbr3000uax-v1",
                               want_version="25.12.4") == []

def test_acceptance_flags_low_space_and_wrong_version():
    problems = acceptance_problems("cudy,wbr3000uax-v1", "24.10.0", 5000,
                                   want_board="cudy,wbr3000uax-v1",
                                   want_version="25.12.4")
    assert len(problems) == 2
```

- [ ] **Step 2: Запустить, убедиться что падает**

Run: `python -m pytest station/tests/test_commands.py -v`
Expected: FAIL, `ModuleNotFoundError`

- [ ] **Step 3: Написать модуль**

```python
# station/commands.py
import json

MIN_FREE_KB = 40 * 1024

def ubi_layout_commands(ubi_dev: str) -> list[str]:
    return [
        f"ubidetach -p {ubi_dev}",
        f"ubiformat {ubi_dev} -y",
        f"ubiattach -p {ubi_dev}",
        "ubimkvol /dev/ubi0 -n 0 -N ubootenv -s 128KiB",
        "ubimkvol /dev/ubi0 -n 1 -N ubootenv2 -s 128KiB",
    ]

def sysupgrade_command(remote_path: str) -> str:
    return f"sysupgrade -n {remote_path}"

def df_command() -> str:
    return "df -Pk /overlay"

def board_command() -> str:
    return "ubus call system board"

def free_space_kb(df_output: str, mount: str = "/overlay") -> int:
    for line in df_output.splitlines():
        fields = line.split()
        if len(fields) >= 6 and fields[-1] == mount:
            return int(fields[3])
    raise ValueError(f"{mount} не найден в выводе df")

def parse_board(json_text: str) -> tuple[str, str]:
    data = json.loads(json_text)
    return data.get("board_name", ""), data.get("release", {}).get("version", "")

def acceptance_problems(board: str, version: str, free_kb: int, *,
                        want_board: str, want_version: str,
                        min_kb: int = MIN_FREE_KB) -> list[str]:
    problems = []
    if board != want_board:
        problems.append(f"плата {board!r} вместо {want_board!r}")
    if version != want_version:
        problems.append(f"версия {version!r} вместо {want_version!r}")
    if free_kb < min_kb:
        problems.append(f"мало места: {free_kb} КБ при минимуме {min_kb} КБ")
    return problems
```

Первая команда из `ubi_layout_commands` может завершиться ненулевым кодом на
роутере, где том ещё не подключён, — это нормально. Обработчик шага знает об
этом и игнорирует код именно у неё, вместо того чтобы прятать ошибки всех
команд через `|| true`, что запрещено `CONTRIBUTING.md`.

- [ ] **Step 4: Запустить, убедиться что проходит**

Run: `python -m pytest station/tests/test_commands.py -v`
Expected: PASS (9 passed)

- [ ] **Step 5: Коммит**

```bash
git add station/commands.py station/tests/test_commands.py
git commit -m "feat(station): команды роутера и приёмка с верным форматом платы"
```

---

### Task 13: Паспорт и журнал шагов

**Files:**
- Create: `station/passport.py`
- Test: `station/tests/test_passport.py`

**Interfaces:**
- Produces:
  - `write_json_atomic(path, obj) -> None` — через временный файл и `os.replace`
  - `@dataclass Passport(...)` с `to_dict()`
  - `save_passport(passport, device_dir) -> pathlib.Path`
  - `load_state(device_dir) -> dict`
  - `record_step(device_dir, name, outcome, detail="") -> None`
  - `done_steps(device_dir) -> list[str]` — только те, у которых `outcome == "ok"`

`state.json` — единственная защита от повторного прохода по уже прошитому
роутеру, поэтому запись атомарная: оборванная запись не должна оставлять
обрезанный JSON, из-за которого оператор удалит файл и начнёт всё сначала.

- [ ] **Step 1: Написать падающий тест**

```python
# station/tests/test_passport.py
import json
from station.passport import (Passport, save_passport, record_step, load_state,
                              done_steps, write_json_atomic)

def test_atomic_write_leaves_no_partial_file(tmp_path):
    target = tmp_path / "state.json"
    write_json_atomic(target, {"a": 1})
    assert json.loads(target.read_text(encoding="utf-8")) == {"a": 1}
    assert list(tmp_path.iterdir()) == [target]   # временный файл убран

def test_save_passport_roundtrip(tmp_path):
    p = Passport(serial="SN123", model="cudy_wbr3000uax-v1", revision="v1",
                 macs=["AA:BB:CC:00:11:22"], stock_version="1.2.3",
                 openwrt_version="25.12.4", written_sha256={"fip": "abc"},
                 wifi_ssid="MOST-1234", steps=[], station_version="0.1.0")
    data = json.loads(save_passport(p, tmp_path).read_text(encoding="utf-8"))
    assert data["serial"] == "SN123"
    assert data["written_sha256"]["fip"] == "abc"

def test_failures_are_recorded_but_not_counted_as_done(tmp_path):
    record_step(tmp_path, "backup", "ok")
    record_step(tmp_path, "write_fip", "fail", "обратное чтение не совпало")
    assert done_steps(tmp_path) == ["backup"]
    steps = load_state(tmp_path)["steps"]
    assert steps[-1]["outcome"] == "fail"
    assert "обратное чтение" in steps[-1]["detail"]

def test_load_state_empty(tmp_path):
    assert load_state(tmp_path) == {}
```

- [ ] **Step 2: Запустить, убедиться что падает**

Run: `python -m pytest station/tests/test_passport.py -v`
Expected: FAIL, `ModuleNotFoundError`

- [ ] **Step 3: Написать модуль**

```python
# station/passport.py
import json, os, pathlib, tempfile, time
from dataclasses import dataclass, asdict

def write_json_atomic(path, obj) -> None:
    path = pathlib.Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=str(path.parent), suffix=".tmp")
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            json.dump(obj, f, ensure_ascii=False, indent=2)
            f.flush()
            os.fsync(f.fileno())
        os.replace(tmp, path)
    except BaseException:
        pathlib.Path(tmp).unlink(missing_ok=True)
        raise

@dataclass
class Passport:
    serial: str
    model: str
    revision: str
    macs: list
    stock_version: str
    openwrt_version: str
    written_sha256: dict
    wifi_ssid: str
    steps: list
    station_version: str

    def to_dict(self) -> dict:
        return asdict(self)

def save_passport(passport: Passport, device_dir) -> pathlib.Path:
    device_dir = pathlib.Path(device_dir)
    path = device_dir / "passport.json"
    data = passport.to_dict()
    data["steps"] = load_state(device_dir).get("steps", [])
    write_json_atomic(path, data)
    return path

def load_state(device_dir) -> dict:
    path = pathlib.Path(device_dir) / "state.json"
    if not path.exists():
        return {}
    return json.loads(path.read_text(encoding="utf-8"))

def record_step(device_dir, name: str, outcome: str, detail: str = "") -> None:
    device_dir = pathlib.Path(device_dir)
    state = load_state(device_dir)
    state.setdefault("steps", []).append(
        {"name": name, "outcome": outcome, "detail": detail, "at": time.time()})
    write_json_atomic(device_dir / "state.json", state)

def done_steps(device_dir) -> list[str]:
    return [s["name"] for s in load_state(device_dir).get("steps", [])
            if s.get("outcome") == "ok"]
```

- [ ] **Step 4: Запустить, убедиться что проходит**

Run: `python -m pytest station/tests/test_passport.py -v`
Expected: PASS (4 passed)

- [ ] **Step 5: Коммит**

```bash
git add station/passport.py station/tests/test_passport.py
git commit -m "feat(station): паспорт и журнал шагов с атомарной записью"
```

---

### Task 14: Машина состояний

**Files:**
- Create: `station/flow.py`
- Test: `station/tests/test_flow.py`

**Interfaces:**
- Consumes: `record_step`, `done_steps` из `station.passport`
- Produces:
  - `STEPS: tuple[str, ...]` — `("artifacts", "network", "privileges", "identify", "access", "backup", "write_fip", "write_bl2", "recovery", "install", "acceptance", "passport")`
  - `next_step(device_dir) -> str | None`
  - `run_flow(device_dir, handlers, *, resume=True) -> None` — при `next_step is None` не делает ничего; отказ шага записывается в журнал и пробрасывается

Две вещи, которых не было раньше. Записи `FIP` и `BL2` — **разные** шаги: падение
между ними оставляет роутер с новым `FIP` и старым `BL2`, и повторять надо только
вторую половину. И завершённое устройство больше не начинается заново: именно
эта ошибка заставила бы станцию переписать загрузчик на роутере, который уже
прошёл приёмку.

- [ ] **Step 1: Написать падающий тест**

```python
# station/tests/test_flow.py
import pytest
from station.flow import STEPS, next_step, run_flow
from station.passport import record_step, load_state

def test_step_order():
    assert STEPS[0] == "artifacts"
    assert STEPS.index("privileges") < STEPS.index("write_fip")
    assert STEPS.index("backup") < STEPS.index("write_fip") < STEPS.index("write_bl2")
    assert STEPS.index("write_bl2") < STEPS.index("recovery") < STEPS.index("install")
    assert STEPS[-1] == "passport"

def test_next_step_fresh(tmp_path):
    assert next_step(tmp_path) == "artifacts"

def test_finished_device_has_no_next_step(tmp_path):
    for s in STEPS:
        record_step(tmp_path, s, "ok")
    assert next_step(tmp_path) is None

def test_finished_device_is_not_reflashed(tmp_path):
    for s in STEPS:
        record_step(tmp_path, s, "ok")
    calls = []
    run_flow(tmp_path, {s: (lambda n=s: calls.append(n)) for s in STEPS})
    assert calls == [], "готовый роутер обязан остаться нетронутым"

def test_resume_continues_after_written_fip(tmp_path):
    upto = STEPS.index("write_fip")
    for s in STEPS[:upto + 1]:
        record_step(tmp_path, s, "ok")
    calls = []
    run_flow(tmp_path, {s: (lambda n=s: calls.append(n)) for s in STEPS})
    assert calls[0] == "write_bl2"
    assert "write_fip" not in calls

def test_failure_stops_and_is_recorded(tmp_path):
    calls = []
    handlers = {s: (lambda n=s: calls.append(n)) for s in STEPS}
    def boom():
        raise RuntimeError("нет доступа")
    handlers["access"] = boom
    with pytest.raises(RuntimeError):
        run_flow(tmp_path, handlers)
    assert "identify" in calls and "backup" not in calls
    assert next_step(tmp_path) == "access"
    last = load_state(tmp_path)["steps"][-1]
    assert last["name"] == "access" and last["outcome"] == "fail"
    assert "нет доступа" in last["detail"]

def test_no_resume_starts_over(tmp_path):
    for s in STEPS[:3]:
        record_step(tmp_path, s, "ok")
    calls = []
    run_flow(tmp_path, {s: (lambda n=s: calls.append(n)) for s in STEPS}, resume=False)
    assert calls == list(STEPS)
```

- [ ] **Step 2: Запустить, убедиться что падает**

Run: `python -m pytest station/tests/test_flow.py -v`
Expected: FAIL, `ModuleNotFoundError`

- [ ] **Step 3: Написать модуль**

```python
# station/flow.py
from .passport import done_steps, record_step

STEPS = (
    "artifacts",     # скачать и сверить официальные файлы
    "network",       # адреса на выбранном интерфейсе
    "privileges",    # право занять UDP 69 — ДО записи загрузчика
    "identify",      # вход в заводской интерфейс, сверка модели и версии
    "access",        # открыть SSH на заводской прошивке
    "backup",        # копии разделов, Factory обязателен
    "write_fip",     # bl31-uboot.fip -> FIP
    "write_bl2",     # preloader.bin  -> BL2
    "recovery",      # TFTP, перезагрузка, ожидание образа восстановления
    "install",       # переразметка ubi и установка системы
    "acceptance",    # плата, версия, свободное место
    "passport",      # паспорт устройства
)

def next_step(device_dir) -> str | None:
    done = set(done_steps(device_dir))
    for step in STEPS:
        if step not in done:
            return step
    return None

def run_flow(device_dir, handlers: dict, *, resume: bool = True) -> None:
    if resume:
        pending = next_step(device_dir)
        if pending is None:
            return
        start = STEPS.index(pending)
    else:
        start = 0

    for step in STEPS[start:]:
        try:
            handlers[step]()
        except Exception as error:
            record_step(device_dir, step, "fail", str(error))
            raise
        record_step(device_dir, step, "ok")
```

- [ ] **Step 4: Запустить, убедиться что проходит**

Run: `python -m pytest station/tests/test_flow.py -v`
Expected: PASS (7 passed)

- [ ] **Step 5: Коммит**

```bash
git add station/flow.py station/tests/test_flow.py
git commit -m "feat(station): машина состояний, раздельные записи, готовое не трогаем"
```

---

### Task 15: SSH через paramiko

**Files:**
- Create: `station/ssh_remote.py`
- Test: `station/tests/test_ssh_remote.py`

**Interfaces:**
- Consumes: `Result` из `station.remote`
- Produces:
  - `build_read_command(path, size) -> str` — `head -c N path` при заданном размере, иначе `cat path`; оба с `2>/dev/null`
  - `class SshRemote` — методы протокола `Remote` плюс `connect()`, `close()`
  - `wait_for_ssh(host, user, passwords, timeout, poll=3) -> SshRemote`
  - `class SshError(Exception)`

`dd bs=1` читал бы раздел по одному байту за системный вызов — минуты вместо
секунд, и это ровно в окне между записью `FIP` и `BL2`, где обрыв питания
убивает роутер. `head -c` читает потоком.

- [ ] **Step 1: Написать падающий тест**

```python
# station/tests/test_ssh_remote.py
import pytest
from station.ssh_remote import build_read_command, wait_for_ssh, SshError

def test_read_full_uses_cat():
    assert build_read_command("/dev/mtd3", None) == "cat /dev/mtd3 2>/dev/null"

def test_read_sized_uses_head_not_dd_bs1():
    cmd = build_read_command("/dev/mtd4", 1048576)
    assert cmd.startswith("head -c 1048576 /dev/mtd4")
    assert "bs=1 " not in cmd

def test_wait_for_ssh_gives_up_with_clear_error(monkeypatch):
    class Never:
        def __init__(self, *a, **k): pass
        def connect(self): raise OSError("connection refused")
        def close(self): pass
    monkeypatch.setattr("station.ssh_remote.SshRemote", Never)
    with pytest.raises(SshError) as e:
        wait_for_ssh("192.168.1.1", "root", [None], timeout=0.2, poll=0.05)
    assert "192.168.1.1" in str(e.value)

def test_wait_for_ssh_returns_first_working(monkeypatch):
    class Once:
        created = []
        def __init__(self, host, user="root", password=None, **k):
            self.password = password
            Once.created.append(password)
        def connect(self):
            if self.password != "good":
                raise OSError("auth failed")
        def close(self): pass
    monkeypatch.setattr("station.ssh_remote.SshRemote", Once)
    got = wait_for_ssh("192.168.1.1", "root", ["bad", "good"], timeout=2, poll=0.05)
    assert got.password == "good"
```

- [ ] **Step 2: Запустить, убедиться что падает**

Run: `python -m pytest station/tests/test_ssh_remote.py -v`
Expected: FAIL, `ModuleNotFoundError`

- [ ] **Step 3: Написать модуль**

```python
# station/ssh_remote.py
import time
from .remote import Result

class SshError(Exception):
    pass

def build_read_command(path: str, size: int | None) -> str:
    if size is None:
        return f"cat {path} 2>/dev/null"
    return f"head -c {size} {path} 2>/dev/null"

class SshRemote:
    def __init__(self, host, user="root", password=None, port=22, timeout=30):
        self.host, self.user, self.password = host, user, password
        self.port, self.timeout = port, timeout
        self._client = None

    def connect(self) -> None:
        import paramiko
        client = paramiko.SSHClient()
        client.set_missing_host_key_policy(paramiko.AutoAddPolicy())
        client.connect(self.host, port=self.port, username=self.user,
                       password=self.password, timeout=self.timeout,
                       allow_agent=False, look_for_keys=False)
        self._client = client

    def close(self) -> None:
        if self._client:
            self._client.close()
            self._client = None

    def run(self, cmd: str) -> Result:
        _, stdout, stderr = self._client.exec_command(cmd, timeout=self.timeout)
        out = stdout.read()
        err = stderr.read()
        return Result(stdout.channel.recv_exit_status(), out, err)

    def upload(self, data: bytes, dest: str) -> None:
        sftp = self._client.open_sftp()
        try:
            with sftp.file(dest, "wb") as f:
                f.write(data)
        finally:
            sftp.close()

    def read(self, path: str, size: int | None = None) -> bytes:
        res = self.run(build_read_command(path, size))
        if res.code != 0:
            raise SshError(f"чтение {path} не удалось: "
                           + res.stderr.decode("utf-8", "replace").strip())
        return res.stdout

    def reboot(self) -> None:
        try:
            self.run("reboot")
        except Exception:
            pass          # соединение рвётся в момент перезагрузки — это норма
        finally:
            self.close()

def wait_for_ssh(host, user, passwords, timeout=180, poll=3) -> SshRemote:
    deadline = time.monotonic() + timeout
    last = "не пробовали"
    while time.monotonic() < deadline:
        for password in passwords:
            candidate = SshRemote(host, user=user, password=password, timeout=5)
            try:
                candidate.connect()
                return candidate
            except Exception as error:
                last = str(error)
                candidate.close()
        time.sleep(poll)
    raise SshError(f"SSH на {host} не поднялся за {timeout} с. Последняя ошибка: {last}")
```

- [ ] **Step 4: Запустить, убедиться что проходит**

Run: `python -m pytest station/tests/test_ssh_remote.py -v`
Expected: PASS (4 passed)

- [ ] **Step 5: Коммит**

```bash
git add station/ssh_remote.py station/tests/test_ssh_remote.py
git commit -m "feat(station): SSH через paramiko, чтение разделов потоком"
```

---

### Task 16: Заводской веб-интерфейс

**Files:**
- Create: `station/stock_ui.py`
- Test: `station/tests/test_stock_ui.py`

**Interfaces:**
- Produces:
  - `@dataclass StockInfo(board_ubus: str, firmware_version: str, macs: list)`
  - `parse_board_from_page(text: str) -> str` — возвращает плату **через запятую** или `""`
  - `parse_firmware_version(text: str) -> str`
  - `parse_macs(text: str) -> list[str]`
  - `class StockUiError(Exception)`
  - `login(page, ip, password) -> None`, `identify(page, ip) -> StockInfo`, `restore_backup(page, ip, path) -> None`
  - `check_identity(info, model, allow_unknown_stock) -> None` — сверяет плату и версию, бросает `StockUiError`

`check_identity` — та самая защита, которой не было: оператор мог задать одну
модель, воткнуть другую и получить в разделы чужой загрузчик.

Селекторы и адреса вынесены в константы модуля. **Они предположительные**:
заводской интерфейс Cudy проверить без железа нельзя, и первая задача на
живом роутере — уточнить их.

- [ ] **Step 1: Написать падающий тест**

```python
# station/tests/test_stock_ui.py
import pytest
from station.models import MODELS
from station.stock_ui import (StockInfo, parse_board_from_page, parse_firmware_version,
                              parse_macs, check_identity, StockUiError)

def test_parse_board_returns_comma_form():
    assert parse_board_from_page("Model: Cudy WBR3000UAX") == "cudy,wbr3000uax-v1"
    assert parse_board_from_page("Cudy WR3000S Router") == "cudy,wr3000s-v1"

def test_parse_board_unknown_is_empty():
    assert parse_board_from_page("Cudy WR3000 v1") == ""

def test_parse_firmware_and_macs():
    page = "Firmware Version: 2.3.5 build 20260114\nMAC: AA:BB:CC:DD:EE:FF"
    assert parse_firmware_version(page).startswith("2.3.5")
    assert parse_macs(page) == ["AA:BB:CC:DD:EE:FF"]

def test_identity_rejects_wrong_model():
    model = MODELS["cudy_wbr3000uax-v1"]
    info = StockInfo("cudy,wr3000s-v1", "2.3.5", [])
    with pytest.raises(StockUiError) as e:
        check_identity(info, model, allow_unknown_stock=True)
    assert "wr3000s" in str(e.value)

def test_identity_accepts_matching_model():
    model = MODELS["cudy_wbr3000uax-v1"]
    check_identity(StockInfo(model.board_ubus, "2.3.5", []), model,
                   allow_unknown_stock=True)

def test_unknown_stock_version_stops_without_flag():
    model = MODELS["cudy_wbr3000uax-v1"]
    info = StockInfo(model.board_ubus, "9.9.9", [])
    with pytest.raises(StockUiError) as e:
        check_identity(info, model, allow_unknown_stock=False)
    assert "9.9.9" in str(e.value)

def test_unsupported_board_gets_its_reason():
    model = MODELS["cudy_wbr3000uax-v1"]
    info = StockInfo("cudy,wr3000-v1", "2.3.5", [])
    with pytest.raises(StockUiError) as e:
        check_identity(info, model, allow_unknown_stock=True)
    assert "16" in str(e.value)
```

- [ ] **Step 2: Запустить, убедиться что падает**

Run: `python -m pytest station/tests/test_stock_ui.py -v`
Expected: FAIL, `ModuleNotFoundError`

- [ ] **Step 3: Написать модуль**

```python
# station/stock_ui.py
import re
from dataclasses import dataclass, field
from .models import Model, unsupported_reason

# Адреса и селекторы заводского интерфейса. ПРЕДПОЛОЖИТЕЛЬНЫЕ: проверить и
# уточнить на живом роутере — это первая задача приёмки на железе.
HOME_URL = "http://{ip}/"
BACKUP_URL = "http://{ip}/cgi-bin/luci/admin/system/backup"
PASSWORD_SELECTORS = ("input[type='password']", "input[name='luci_password']",
                      "input[name='password']")
SUBMIT_SELECTORS = ("button[type='submit']", "input[type='submit']")
FILE_SELECTOR = "input[type='file']"
RESTORE_SELECTORS = ("input[name='cbid.backup.1.restore']",
                     "button:has-text('Restore')")
PROCEED_SELECTORS = ("input[name='cbid.backup.1.proceed']",
                     "button:has-text('Proceed')")

_BOARDS = (("WBR3000UAX", "cudy,wbr3000uax-v1"),
           ("WR3000S", "cudy,wr3000s-v1"),
           ("WR3000H", "cudy,wr3000h-v1"),
           ("WR3000", "cudy,wr3000-v1"))      # последним: самое общее имя
_VERSION = re.compile(r"Firmware\s*Version[:\s]*([0-9][\w.\- ]*)", re.I)
_MAC = re.compile(r"\b([0-9A-Fa-f]{2}(?::[0-9A-Fa-f]{2}){5})\b")

class StockUiError(Exception):
    pass

@dataclass
class StockInfo:
    board_ubus: str
    firmware_version: str
    macs: list = field(default_factory=list)

def parse_board_from_page(text: str) -> str:
    upper = text.upper()
    for marker, board in _BOARDS:
        if marker in upper:
            return board
    return ""

def parse_firmware_version(text: str) -> str:
    m = _VERSION.search(text)
    return m.group(1).strip() if m else ""

def parse_macs(text: str) -> list[str]:
    seen = []
    for m in _MAC.finditer(text):
        value = m.group(1).upper()
        if value not in seen:
            seen.append(value)
    return seen

def check_identity(info: StockInfo, model: Model, allow_unknown_stock: bool) -> None:
    if not info.board_ubus:
        raise StockUiError(
            "Не удалось опознать модель по заводскому интерфейсу. "
            "Проверьте селекторы в station/stock_ui.py.")

    reason = unsupported_reason(info.board_ubus)
    if reason:
        raise StockUiError(reason)

    if info.board_ubus != model.board_ubus:
        raise StockUiError(
            f"Подключён {info.board_ubus}, а запрошена прошивка для "
            f"{model.board_ubus}. Записывать чужой загрузчик нельзя — "
            f"это необратимо. Укажите верный --model.")

    if model.known_stock_versions and info.firmware_version not in model.known_stock_versions:
        if not allow_unknown_stock:
            raise StockUiError(
                f"Заводская прошивка {info.firmware_version!r} не в списке "
                f"проверенных {model.known_stock_versions}. Способ открыть "
                f"доступ может не сработать. Повторите с --allow-unknown-stock, "
                f"если готовы проверить, и впишите версию в models.py.")
    elif not model.known_stock_versions and not allow_unknown_stock:
        raise StockUiError(
            f"Для {model.key} ни одна заводская версия ещё не проверена "
            f"(сейчас на роутере {info.firmware_version!r}). Повторите с "
            f"--allow-unknown-stock и впишите версию в models.py после успеха.")

def _fill_first(page, selectors, value) -> bool:
    for selector in selectors:
        if page.query_selector(selector):
            page.fill(selector, value)
            return True
    return False

def _click_first(page, selectors) -> bool:
    for selector in selectors:
        if page.query_selector(selector):
            page.click(selector)
            return True
    return False

def login(page, ip: str, password: str) -> None:
    page.goto(HOME_URL.format(ip=ip))
    if not _fill_first(page, PASSWORD_SELECTORS, password):
        return                      # интерфейс не спросил пароль
    if not _click_first(page, SUBMIT_SELECTORS):
        raise StockUiError("Поле пароля найдено, а кнопки входа нет — "
                           "уточните SUBMIT_SELECTORS.")
    page.wait_for_load_state("networkidle")

def identify(page, ip: str) -> StockInfo:
    page.goto(HOME_URL.format(ip=ip))
    text = page.content()
    return StockInfo(parse_board_from_page(text), parse_firmware_version(text),
                     parse_macs(text))

def restore_backup(page, ip: str, backup_path) -> None:
    page.goto(BACKUP_URL.format(ip=ip))
    if not page.query_selector(FILE_SELECTOR):
        raise StockUiError("Поле загрузки файла не найдено — уточните "
                           "BACKUP_URL и FILE_SELECTOR.")
    page.set_input_files(FILE_SELECTOR, str(backup_path))
    _click_first(page, RESTORE_SELECTORS)
    _click_first(page, PROCEED_SELECTORS)
```

- [ ] **Step 4: Запустить, убедиться что проходит**

Run: `python -m pytest station/tests/test_stock_ui.py -v`
Expected: PASS (7 passed)

- [ ] **Step 5: Коммит**

```bash
git add station/stock_ui.py station/tests/test_stock_ui.py
git commit -m "feat(station): заводской интерфейс, сверка модели и версии"
```

---

### Task 17: Обработчики шагов

**Files:**
- Create: `station/handlers.py`
- Test: `station/tests/test_handlers.py`

**Interfaces:**
- Consumes: всё предыдущее
- Produces:
  - `@dataclass Context` — поля: `model`, `serial`, `os_name`, `iface`, `device_dir`, `cache_dir`, `assets_dir`, `allow_unknown_stock`, `stock_password`, `fetch`, `open_page`, `connect_stock`, `connect_recovery`, `connect_openwrt`, `make_tftp`, `wifi_ssid`; метод `artifact_path(kind) -> pathlib.Path`
  - `make_handlers(ctx) -> dict[str, Callable[[], None]]` — по обработчику на каждый шаг `STEPS`

Каждый обработчик самодостаточен: он заново получает соединение и заново
вычисляет пути. Поэтому возобновление работает и после перезапуска процесса,
а не только внутри одного прогона.

- [ ] **Step 1: Написать падающий тест**

```python
# station/tests/test_handlers.py
import pytest
from station.flow import STEPS
from station.handlers import Context, make_handlers
from station.models import MODELS
from station.remote import FakeRemote, Result
from station.mtd import MtdError

PROC = Result(0, (b'dev:    size   erasesize  name\n'
                  b'mtd0: 00100000 00020000 "BL2"\n'
                  b'mtd3: 00080000 00020000 "Factory"\n'
                  b'mtd4: 00080000 00020000 "FIP"\n'
                  b'mtd5: 07800000 00020000 "ubi"\n'), b"")

def _ctx(tmp_path, remote=None, **over):
    remote = remote or FakeRemote(responses={"cat /proc/mtd": PROC},
                                  files={"/dev/mtd0": b"bl2", "/dev/mtd3": b"fac",
                                         "/dev/mtd4": b"fip", "/dev/mtd5": b"ubi"})
    base = dict(
        model=MODELS["cudy_wbr3000uax-v1"], serial="SN1", os_name="linux",
        iface="eth0", device_dir=tmp_path / "dev", cache_dir=tmp_path / "cache",
        assets_dir=tmp_path / "assets", allow_unknown_stock=True,
        stock_password="admin", fetch=lambda url: b"", open_page=None,
        connect_stock=lambda: remote, connect_recovery=lambda: remote,
        connect_openwrt=lambda: remote, make_tftp=None, wifi_ssid="MOST-1")
    base.update(over)
    return Context(**base)

def test_handlers_cover_every_step(tmp_path):
    handlers = make_handlers(_ctx(tmp_path))
    assert set(handlers) == set(STEPS)
    assert all(callable(h) for h in handlers.values())

def test_backup_handler_writes_factory_copy(tmp_path):
    ctx = _ctx(tmp_path)
    make_handlers(ctx)["backup"]()
    assert (ctx.device_dir / "partitions" / "Factory.bin").read_bytes() == b"fac"

def test_backup_handler_refuses_without_factory(tmp_path):
    thin = Result(0, b'dev:    size   erasesize  name\nmtd0: 00100000 00020000 "BL2"\n', b"")
    remote = FakeRemote(responses={"cat /proc/mtd": thin}, files={"/dev/mtd0": b"bl2"})
    with pytest.raises(MtdError):
        make_handlers(_ctx(tmp_path, remote=remote))["backup"]()

def test_artifact_path_is_derived_not_stored(tmp_path):
    ctx = _ctx(tmp_path)
    path = ctx.artifact_path("fip")
    assert path.parent == ctx.cache_dir
    assert "bl31-uboot.fip" in path.name

def test_acceptance_handler_reports_problems(tmp_path):
    from station.commands import board_command, df_command
    remote = FakeRemote(responses={
        board_command(): Result(0, b'{"board_name":"cudy,wr3000s-v1",'
                                   b'"release":{"version":"25.12.4"}}', b""),
        df_command(): Result(0, b"Filesystem 1024-blocks Used Available Capacity Mounted on\n"
                                b"overlayfs:/overlay 102400 1024 101376 1% /overlay\n", b""),
    })
    with pytest.raises(RuntimeError) as e:
        make_handlers(_ctx(tmp_path, connect_openwrt=lambda: remote))["acceptance"]()
    assert "wr3000s" in str(e.value)
```

- [ ] **Step 2: Запустить, убедиться что падает**

Run: `python -m pytest station/tests/test_handlers.py -v`
Expected: FAIL, `ModuleNotFoundError`

- [ ] **Step 3: Написать модуль**

```python
# station/handlers.py
import pathlib, time
from dataclasses import dataclass
from typing import Callable

from . import commands, mtd, network, privileges, stock_ui
from .artifacts import ensure_artifacts, sha256_file
from .models import Model, artifact
from .passport import Passport, save_passport, load_state
from .thirdparty import load_thirdparty

TFTP_HOST = "192.168.1.254"

@dataclass
class Context:
    model: Model
    serial: str
    os_name: str
    iface: str
    device_dir: pathlib.Path
    cache_dir: pathlib.Path
    assets_dir: pathlib.Path
    allow_unknown_stock: bool
    stock_password: str
    fetch: Callable
    open_page: Callable | None
    connect_stock: Callable
    connect_recovery: Callable
    connect_openwrt: Callable
    make_tftp: Callable | None
    wifi_ssid: str

    def artifact_path(self, kind: str) -> pathlib.Path:
        return pathlib.Path(self.cache_dir) / artifact(self.model, kind).filename

def make_handlers(ctx: Context) -> dict:
    device_dir = pathlib.Path(ctx.device_dir)
    parts_dir = device_dir / "partitions"

    def step_artifacts():
        ensure_artifacts(ctx.model, ctx.cache_dir, ctx.fetch)

    def step_network():
        import subprocess
        argv = network.interface_command(ctx.os_name, ctx.iface)
        output = subprocess.run(argv, capture_output=True, text=True).stdout
        missing = network.check_ready(network.parse_addresses(ctx.os_name, output))
        if missing:
            raise RuntimeError(
                "Интерфейс не готов:\n  " + "\n  ".join(missing) +
                "\nНастроить: " + network.setup_command(ctx.os_name, ctx.iface))

    def step_privileges():
        privileges.require_tftp_port(ctx.os_name, TFTP_HOST, 69)

    def step_identify():
        with ctx.open_page() as page:
            stock_ui.login(page, ctx.model.stock_ip, ctx.stock_password)
            info = stock_ui.identify(page, ctx.model.stock_ip)
        stock_ui.check_identity(info, ctx.model, ctx.allow_unknown_stock)
        _remember(device_dir, "stock", {"version": info.firmware_version,
                                        "macs": info.macs})

    def step_access():
        backup = load_thirdparty(ctx.model.settings_backup, ctx.assets_dir)
        with ctx.open_page() as page:
            stock_ui.login(page, ctx.model.stock_ip, ctx.stock_password)
            stock_ui.restore_backup(page, ctx.model.stock_ip, backup)
        time.sleep(5)
        ctx.connect_stock().close()

    def step_backup():
        remote = ctx.connect_stock()
        parts = mtd.read_partitions(remote)
        mtd.require_partitions(parts, ctx.model.required_partitions)
        mtd.backup_all(remote, parts, parts_dir, ctx.model.required_partitions)

    def _write(kind: str, partition: str):
        remote = ctx.connect_stock()
        mtd.insmod_mtd_rw(remote, load_thirdparty(ctx.model.mtd_rw, ctx.assets_dir))
        parts = mtd.read_partitions(remote)
        target = mtd.find_partition(parts, partition)
        local = ctx.artifact_path(kind)
        mtd.write_and_verify(remote, target, local)
        _remember(device_dir, "written",
                  {**load_state(device_dir).get("written", {}),
                   kind: sha256_file(local)})

    def step_recovery():
        image = ctx.artifact_path("recovery")
        server = ctx.make_tftp(image.name, image.read_bytes())
        server.start()
        try:
            ctx.connect_stock().reboot()
            remote = ctx.connect_recovery()
            remote.close()
        finally:
            server.stop()
        if not server.served and not server.requests:
            raise RuntimeError(
                "Загрузчик не запросил ни одного файла по TFTP. Проверьте кабель "
                "и адрес 192.168.1.254.")

    def step_install():
        remote = ctx.connect_recovery()
        ubi = mtd.find_partition(mtd.read_partitions(remote), "ubi")
        for number, cmd in enumerate(commands.ubi_layout_commands(ubi.dev)):
            result = remote.run(cmd)
            if result.code != 0 and number != 0:
                raise RuntimeError(f"{cmd}: "
                                   + result.stderr.decode("utf-8", "replace").strip())
        image = ctx.artifact_path("sysupgrade")
        mtd.upload_and_verify(remote, image, "/tmp/sysupgrade.itb")
        remote.run(commands.sysupgrade_command("/tmp/sysupgrade.itb"))
        remote.close()
        ctx.connect_openwrt().close()

    def step_acceptance():
        remote = ctx.connect_openwrt()
        board, version = commands.parse_board(remote.run(commands.board_command()).text)
        free = commands.free_space_kb(remote.run(commands.df_command()).text)
        problems = commands.acceptance_problems(
            board, version, free,
            want_board=ctx.model.board_ubus,
            want_version=ctx.model.openwrt_version)
        if problems:
            raise RuntimeError("Приёмка не пройдена: " + "; ".join(problems))
        _remember(device_dir, "accepted", {"board": board, "version": version,
                                           "free_kb": free})

    def step_passport():
        state = load_state(device_dir)
        from .models import VERSION
        save_passport(Passport(
            serial=ctx.serial, model=ctx.model.key, revision="v1",
            macs=state.get("stock", {}).get("macs", []),
            stock_version=state.get("stock", {}).get("version", ""),
            openwrt_version=ctx.model.openwrt_version,
            written_sha256=state.get("written", {}),
            wifi_ssid=ctx.wifi_ssid, steps=[], station_version=VERSION,
        ), device_dir)

    return {
        "artifacts": step_artifacts,
        "network": step_network,
        "privileges": step_privileges,
        "identify": step_identify,
        "access": step_access,
        "backup": step_backup,
        "write_fip": lambda: _write("fip", "FIP"),
        "write_bl2": lambda: _write("preloader", "BL2"),
        "recovery": step_recovery,
        "install": step_install,
        "acceptance": step_acceptance,
        "passport": step_passport,
    }

def _remember(device_dir, key: str, value) -> None:
    from .passport import write_json_atomic
    state = load_state(device_dir)
    state[key] = value
    write_json_atomic(pathlib.Path(device_dir) / "state.json", state)
```

- [ ] **Step 4: Запустить, убедиться что проходит**

Run: `python -m pytest station/tests/test_handlers.py -v`
Expected: PASS (5 passed)

- [ ] **Step 5: Коммит**

```bash
git add station/handlers.py station/tests/test_handlers.py
git commit -m "feat(station): обработчики шагов, самодостаточные при возобновлении"
```

---

### Task 18: Точка входа и гейты

**Files:**
- Create: `station/app.py`
- Create: `station/__main__.py`
- Test: `station/tests/test_app.py`

**Interfaces:**
- Produces: `build_parser() -> argparse.ArgumentParser`, `main(argv) -> int`
- Аргументы: `--serial` (обязателен), `--model` (обязателен), `--iface` (обязателен), `--ssid`, `--assets`, `--cache`, `--root`, `--stock-password`, `--allow-untested`, `--allow-unknown-stock`, `--no-resume`, `--dry-run`

Коды возврата: `0` — успех, `2` — неизвестная модель, `3` — непроверенная
модель без флага, `4` — беспроводной интерфейс без подтверждения, `1` — ошибка
в ходе работы.

- [ ] **Step 1: Написать падающий тест**

```python
# station/tests/test_app.py
from station.app import main

BASE = ["--serial", "SN1", "--iface", "eth0", "--ssid", "MOST-1", "--dry-run"]

def test_unknown_model_lists_known(tmp_path, capsys):
    code = main(BASE + ["--model", "cudy_wr3000-v1", "--root", str(tmp_path)])
    assert code == 2
    assert "cudy_wbr3000uax-v1" in capsys.readouterr().out

def test_untested_model_requires_flag(tmp_path):
    assert main(BASE + ["--model", "cudy_wr3000s-v1", "--root", str(tmp_path)]) == 3

def test_untested_model_allowed_with_flag(tmp_path):
    assert main(BASE + ["--model", "cudy_wr3000s-v1", "--allow-untested",
                        "--root", str(tmp_path)]) == 0

def test_tested_model_passes(tmp_path):
    assert main(BASE + ["--model", "cudy_wbr3000uax-v1", "--root", str(tmp_path)]) == 0

def test_wireless_interface_is_refused(tmp_path):
    argv = ["--serial", "SN1", "--iface", "wlan0", "--ssid", "MOST-1", "--dry-run",
            "--model", "cudy_wbr3000uax-v1", "--root", str(tmp_path)]
    assert main(argv) == 4

def test_device_dir_is_keyed_by_serial(tmp_path):
    main(BASE + ["--model", "cudy_wbr3000uax-v1", "--root", str(tmp_path)])
    assert (tmp_path / "devices" / "SN1").exists()
```

- [ ] **Step 2: Запустить, убедиться что падает**

Run: `python -m pytest station/tests/test_app.py -v`
Expected: FAIL, `ModuleNotFoundError`

- [ ] **Step 3: Написать модули**

```python
# station/app.py
import argparse, pathlib, platform
from .models import MODELS
from .network import looks_wireless

DEFAULT_ROOT = pathlib.Path.home() / ".flashing-station"

def build_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(
        prog="station",
        description="Прошивка роутера Cudy официальным OpenWrt одной командой")
    p.add_argument("--serial", required=True,
                   help="серийный номер с наклейки — ключ устройства и паспорта")
    p.add_argument("--model", required=True, help="ключ модели, см. station/models.py")
    p.add_argument("--iface", required=True, help="сетевой интерфейс, кабель")
    p.add_argument("--ssid", default="", help="имя сети Wi-Fi для паспорта")
    p.add_argument("--root", default=str(DEFAULT_ROOT))
    p.add_argument("--assets", default=None)
    p.add_argument("--cache", default=None)
    p.add_argument("--stock-password", default="admin")
    p.add_argument("--allow-untested", action="store_true")
    p.add_argument("--allow-unknown-stock", action="store_true")
    p.add_argument("--no-resume", action="store_true")
    p.add_argument("--dry-run", action="store_true")
    return p

def main(argv) -> int:
    args = build_parser().parse_args(argv)

    model = MODELS.get(args.model)
    if model is None:
        print(f"Неизвестная модель {args.model!r}.")
        print("Известные: " + ", ".join(sorted(MODELS)))
        return 2

    if not model.tested and not args.allow_untested:
        print(f"{model.key} ещё не проверена на живом железе. "
              f"Повторите с --allow-untested, если готовы проверить.")
        return 3

    if looks_wireless(args.iface) and not args.dry_run:
        print(f"{args.iface} похож на беспроводной. Прошивка идёт только по кабелю: "
              f"Wi-Fi роутера в процессе пропадает.")
        return 4
    if looks_wireless(args.iface):
        return 4

    root = pathlib.Path(args.root)
    device_dir = root / "devices" / args.serial
    device_dir.mkdir(parents=True, exist_ok=True)

    if args.dry_run:
        print(f"OK (dry-run): {model.key}, OpenWrt {model.openwrt_version}, "
              f"серийный {args.serial}, каталог {device_dir}")
        return 0

    from .flow import run_flow
    from .handlers import make_handlers
    from .wiring import make_context

    ctx = make_context(model, args, root, device_dir, platform.system())
    run_flow(device_dir, make_handlers(ctx), resume=not args.no_resume)
    print(f"Готово: {model.key}, серийный {args.serial}. "
          f"Паспорт: {device_dir / 'passport.json'}")
    return 0
```

```python
# station/__main__.py
import sys
from .app import main

if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
```

- [ ] **Step 4: Запустить, убедиться что проходит**

Run: `python -m pytest station/tests/test_app.py -v`
Expected: PASS (6 passed)

- [ ] **Step 5: Коммит**

```bash
git add station/app.py station/__main__.py station/tests/test_app.py
git commit -m "feat(station): точка входа, гейты модели, серийника и интерфейса"
```

---

### Task 19: Сборка контекста

**Files:**
- Create: `station/wiring.py`
- Test: `station/tests/test_wiring.py`

**Interfaces:**
- Consumes: `Context` из `station.handlers`
- Produces:
  - `http_fetch(url) -> bytes`
  - `page_opener(headless=True) -> Callable[[], ContextManager]`
  - `make_context(model, args, root, device_dir, os_name) -> Context`

- [ ] **Step 1: Написать падающий тест**

```python
# station/tests/test_wiring.py
import pathlib
from station.flow import STEPS
from station.handlers import make_handlers
from station.models import MODELS
from station.wiring import make_context

class _Args:
    serial = "SN1"
    iface = "eth0"
    ssid = "MOST-1"
    assets = None
    cache = None
    stock_password = "admin"
    allow_unknown_stock = False

def test_context_fills_every_field(tmp_path):
    ctx = make_context(MODELS["cudy_wbr3000uax-v1"], _Args(), tmp_path,
                       tmp_path / "devices" / "SN1", "linux")
    assert ctx.serial == "SN1"
    assert ctx.cache_dir == pathlib.Path(tmp_path) / "cache"
    assert ctx.assets_dir == pathlib.Path(tmp_path) / "assets"
    assert callable(ctx.fetch) and callable(ctx.connect_stock)
    assert callable(ctx.make_tftp) and callable(ctx.open_page)

def test_handlers_build_from_real_context(tmp_path):
    ctx = make_context(MODELS["cudy_wbr3000uax-v1"], _Args(), tmp_path,
                       tmp_path / "devices" / "SN1", "linux")
    handlers = make_handlers(ctx)
    assert set(handlers) == set(STEPS)

def test_explicit_dirs_win(tmp_path):
    args = _Args()
    args.assets = str(tmp_path / "a")
    args.cache = str(tmp_path / "c")
    ctx = make_context(MODELS["cudy_wbr3000uax-v1"], args, tmp_path,
                       tmp_path / "d", "linux")
    assert ctx.assets_dir == pathlib.Path(tmp_path / "a")
    assert ctx.cache_dir == pathlib.Path(tmp_path / "c")
```

- [ ] **Step 2: Запустить, убедиться что падает**

Run: `python -m pytest station/tests/test_wiring.py -v`
Expected: FAIL, `ModuleNotFoundError`

- [ ] **Step 3: Написать модуль**

```python
# station/wiring.py
import contextlib, pathlib, urllib.request

from .handlers import Context, TFTP_HOST
from .ssh_remote import wait_for_ssh
from .tftp import ReadOnlyTftp

STOCK_SSH_TIMEOUT = 120
RECOVERY_SSH_TIMEOUT = 240
OPENWRT_SSH_TIMEOUT = 300

def http_fetch(url: str) -> bytes:
    with urllib.request.urlopen(url, timeout=120) as response:
        return response.read()

def page_opener(headless: bool = True):
    @contextlib.contextmanager
    def opener():
        from playwright.sync_api import sync_playwright
        with sync_playwright() as playwright:
            browser = playwright.chromium.launch(headless=headless)
            try:
                yield browser.new_page()
            finally:
                browser.close()
    return opener

def make_context(model, args, root, device_dir, os_name) -> Context:
    root = pathlib.Path(root)
    assets = pathlib.Path(args.assets) if args.assets else root / "assets"
    cache = pathlib.Path(args.cache) if args.cache else root / "cache"

    def connect_stock():
        return wait_for_ssh(model.stock_ip, "root",
                            [args.stock_password, "", None],
                            timeout=STOCK_SSH_TIMEOUT)

    def connect_recovery():
        return wait_for_ssh(model.recovery_ip, "root", ["", None],
                            timeout=RECOVERY_SSH_TIMEOUT)

    def connect_openwrt():
        return wait_for_ssh(model.recovery_ip, "root", ["", None],
                            timeout=OPENWRT_SSH_TIMEOUT)

    def make_tftp(filename, data):
        return ReadOnlyTftp(filename, data, host=TFTP_HOST, port=69)

    return Context(
        model=model, serial=args.serial, os_name=os_name, iface=args.iface,
        device_dir=pathlib.Path(device_dir), cache_dir=cache, assets_dir=assets,
        allow_unknown_stock=args.allow_unknown_stock,
        stock_password=args.stock_password, fetch=http_fetch,
        open_page=page_opener(), connect_stock=connect_stock,
        connect_recovery=connect_recovery, connect_openwrt=connect_openwrt,
        make_tftp=make_tftp, wifi_ssid=args.ssid,
    )
```

- [ ] **Step 4: Запустить, убедиться что проходит**

Run: `python -m pytest station/tests/test_wiring.py -v`
Expected: PASS (3 passed)

- [ ] **Step 5: Коммит**

```bash
git add station/wiring.py station/tests/test_wiring.py
git commit -m "feat(station): сборка контекста из настоящих зависимостей"
```

---

### Task 20: Прогон, документация, приёмка на железе

**Files:**
- Create: `station/README.md`
- Create: `docs/superpowers/plans/2026-09-21-flashing-station-hardware-checklist.md`
- Modify: `CHANGELOG.md`

- [ ] **Step 1: Прогнать весь набор**

Run: `python -m pytest station/tests -v`
Expected: PASS, около 80 проверок, ни одной ошибки

- [ ] **Step 2: Написать `station/README.md`**

```markdown
# Станция прошивки

Ведёт роутер Cudy от заводского состояния до чистого официального OpenWrt.

## Что нужно один раз

1. `pip install -e ".[dev]"`, затем `playwright install chromium`.
2. Положить в `~/.flashing-station/assets/` два файла: `mtd-rw.ko` и
   `settings_v2_@keeneticported.bin`. Их суммы закреплены в `station/models.py`;
   файл с другой суммой станция не примет.
3. Подключить роутер **кабелем** и настроить интерфейс: адрес из
   `192.168.10.0/24` и дополнительный `192.168.1.254/24`.

## Запуск

    sudo python -m station --serial SN12345 --model cudy_wbr3000uax-v1 \
        --iface eth0 --ssid MOST-12345

`sudo` нужен для UDP-порта 69: его ждёт загрузчик при восстановлении.

## Если прервалось

Повторите ту же команду — станция продолжит с первого невыполненного шага.
Готовое устройство повторно не прошивается.

**Никогда не выключайте питание между шагами `write_fip` и `write_bl2`.**
Это единственное место, где роутер можно потерять. Копии разделов лежат в
`~/.flashing-station/devices/<серийный>/partitions/`; с ними роутер
восстанавливается программатором.
```

- [ ] **Step 3: Написать чек-лист приёмки на железе**

```markdown
# Станция прошивки: приёмка на железе

Выполняется вручную, до того как этап считается закрытым. Тесты в CI проверяют
логику без роутера; здесь проверяется то, что без роутера проверить нельзя.

## WBR3000UAX (основная модель)

- [ ] Записать версию заводской прошивки и вписать её в `known_stock_versions`.
- [ ] Уточнить селекторы заводского интерфейса в `station/stock_ui.py`
      (`PASSWORD_SELECTORS`, `BACKUP_URL`, `FILE_SELECTOR`) — они предположительные.
- [ ] Записать имя файла, которое загрузчик запрашивает по TFTP
      (`server.requests` после шага `recovery`), и сверить с именем образа.
- [ ] Полный проход от заводского состояния до приёмки.
- [ ] Прервать станцию после `write_fip`, запустить заново — убедиться, что
      повторяется только `write_bl2`.
- [ ] Запустить станцию на уже готовом роутере — убедиться, что она ничего не делает.
- [ ] Проверить копию `Factory`: размер и то, что она не пуста.

## WR3000S

- [ ] Снять sha256 файла настроек и вписать в `models.py` вместо `None`.
- [ ] Проверить, что имена разделов совпадают с WBR3000UAX.
- [ ] Полный проход с `--allow-untested`; после успеха снять `tested=False`.

## Долг из docs/AUDIT.md

- [ ] Прогнать `tests/test_router_provisioner.sh` на свежепрошитом роутере —
      это тот самый «реальный smoke test на чистом OpenWrt», которого просил аудит.
```

- [ ] **Step 4: Дописать `CHANGELOG.md`**

В раздел `[Unreleased]` добавить:

```markdown
### Добавлено

- Станция прошивки (`station/`): роутер Cudy проходит от заводского состояния
  до чистого официального OpenWrt одной командой, на macOS, Linux и Windows.
  Контрольные суммы образов закреплены в коде, загрузчик читается обратно до
  перезагрузки, копия раздела Factory обязательна.
```

- [ ] **Step 5: Коммит**

```bash
git add station/README.md CHANGELOG.md \
    docs/superpowers/plans/2026-09-21-flashing-station-hardware-checklist.md
git commit -m "docs(station): руководство, чек-лист приёмки на железе, CHANGELOG"
```

---

## Самопроверка

Проверено построчным сличением со спекой, а не по памяти.

**Покрытие шагов спеки.** Десять шагов «Порядка работы» разложены так:
подготовка файлов — T3; сеть — T11 и обработчик в T17; вход и опознание —
T16 с обязательной сверкой модели; доступ — T16 и T17 (заливка файла настроек
через `load_thirdparty`); копии — T7 с обязательным `Factory`; запись
загрузчика — T8, два раздельных шага в T14, явное соответствие в T1;
восстановление по TFTP — T9, перезагрузка и ожидания в T17; установка — T12 и
T17 с заливкой образа и сверкой суммы на роутере; приёмка — T12 и T17; паспорт
— T13 и T17. Проверка прав на порт 69 — отдельный шаг T10, стоит **до** записи.

**Чем закрыты находки рецензии.** Сверка опознанной модели с заданной —
`check_identity` (T16). Гейт заводской версии — там же, плюс `--allow-unknown-stock`.
Повторный проход по готовому устройству — `run_flow` при `next_step is None`
(T14, тест `test_finished_device_is_not_reflashed`). Заливка `mtd-rw.ko` —
`insmod_mtd_rw` через `upload_and_verify` (T8), вызывается из `_write` (T17).
Пароль — `--stock-password` и `login` (T16, T18). Перезагрузка — `Remote.reboot`
(T5, T15) и шаг `recovery` (T17). Права на порт — T10. Соответствие
файл↔раздел — `WriteTarget` (T1). Обязательность `Factory` —
`require_partitions` и `backup_all` (T6, T7). Разбивка TFTP — `split_blocks`
с тестом на кратность 512 (T9). Разбор `sha256sums` — `strip` до `lstrip` с
тестом на два пробела (T3). Формат платы — запятая в `board_ubus`, тест на
путаницу с подчёркиванием (T12). Чтение потоком — `head -c` (T15). Раздельные
потоки — `Result` (T5). Размер файла против раздела — `write_and_verify` (T8).
Подшаги записи — `write_fip` и `write_bl2` (T14). Заливка образа и сверка на
роутере — `step_install` (T17). `pyproject.toml` — T2, до первого использования.
Ключ по серийному номеру — T18. Атомарная запись состояния — T13. Отказы в
журнале — `run_flow` (T14). Сумма файла настроек для WR3000S — `None` с
объяснением (T1, T4). `df -Pk` как в `lib/system.sh` — T12. Отказ от WR3000 с
причиной — `UNSUPPORTED` и `check_identity` (T1, T16). Заполнение паспорта —
`step_passport` (T17). Долг аудита о закреплении сумм — закреплённые константы
(T1, T3); долг о smoke test — чек-лист T20.

**Типы.** `Result` (T5) используется в T6, T8, T15, T17. `Partition` (T6) — в
T7, T8, T17. `Model` (T1) — везде. `Context` (T17) собирается в T19 и
проверяется тестом, который строит из него настоящие обработчики.
`load_thirdparty` вызывается в T17 дважды, `find_model` и `unsupported_reason`
— в T16, `artifact` — в T17. Мёртвого кода нет.

**Чего план не делает и почему.** Селекторы заводского интерфейса
предположительны — без роутера их проверить нельзя, поэтому они вынесены в
константы и вписаны первым пунктом в чек-лист приёмки. Запасной путь через
официальную переходную прошивку Cudy не реализуется, пока файл настроек
работает; шаг `identify` ловит незнакомую версию до того, как что-то изменено.
Зеркало официальных образов на случай переезда релиза в архив не делается —
достаточно кэша и закреплённых сумм, но это осознанный риск, а не недосмотр.
