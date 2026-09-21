# Станция прошивки — план реализации

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Кроссплатформенная станция на Python, которая ведёт роутер Cudy от заводского состояния до чистого официального OpenWrt: сверка сумм, обратное чтение загрузчика, копия Factory, один заход.

**Architecture:** Пакет `station/` с модулями по одной ответственности. Ядро (`mtd`, `flow`, `artifacts`, `tftp`, `passport`) не знает о настоящем роутере — оно работает через объект `Remote` с методами `run/upload/read`. Это граница, по которой всё проверяется в CI без железа. Модули `stock_ui` (Playwright) и `remote` (paramiko) — единственные, кому нужно живое устройство.

**Tech Stack:** Python 3.11+, paramiko (SSH), Playwright (заводской веб-интерфейс), стандартная библиотека для TFTP и HTTP.

## Global Constraints

- Python 3.11+; работает на macOS, Linux, Windows.
- Пакет в каталоге `station/`, запуск `python -m station`.
- Версия OpenWrt закреплена в описании модели: **25.12.4**. Не «последняя».
- Официальные файлы качаются с `https://downloads.openwrt.org/releases/25.12.4/targets/mediatek/filogic/` и сверяются с тамошним `sha256sums`.
- Сторонние файлы (`settings_v2_@keeneticported.bin`, `mtd-rw.ko`) в репозиторий **не кладутся**: берутся из `~/.flashing-station/assets/`, принимаются только по закреплённой sha256.
- Рабочий каталог станции — `~/.flashing-station/` (`assets/`, `cache/`, `devices/<mac>/`).
- Каждый шаг либо подтверждён проверкой, либо станция останавливается с понятным сообщением; переход к следующему состоянию — только после подтверждения.
- Пароли в файлы не пишутся.
- Известные константы (проверены по разобранному экземпляру утилиты):
  - заводской адрес `192.168.10.1`, восстановление `192.168.1.1`, адрес ПК для TFTP `192.168.1.254/24`;
  - раздел sysupgrade называется `ubi`; тома создаются `ubootenv` (128 KiB) и `ubootenv2` (128 KiB);
  - `preloader.bin` одинаков для обеих моделей; `bl31-uboot.fip` и образы — свои;
  - sha256 `mtd-rw.ko` = `1ad25a1ea33a9467aa4e0db87647a0b16e125b79bf1c5241f67f5d050e026787` (5320 байт);
  - sha256 файла настроек WBR3000UAX = `df725c26662321f0b65cfab26197634cef76629fc124b69eb49d436c309a0e66` (23334 байта).

---

### Task 1: Каркас пакета и описания моделей

**Files:**
- Create: `station/__init__.py`
- Create: `station/models.py`
- Test: `station/tests/test_models.py`

**Interfaces:**
- Produces:
  - `@dataclass(frozen=True) Artifact(kind: str, filename: str, sha256: str | None)`
  - `@dataclass(frozen=True) ThirdPartyFile(name: str, sha256: str, size: int)`
  - `@dataclass(frozen=True) Model(key: str, board: str, openwrt_version: str, stock_ip: str, flash_mb: int, tested: bool, artifacts: tuple[Artifact, ...], settings_backup: ThirdPartyFile, mtd_rw: ThirdPartyFile, known_stock_versions: tuple[str, ...])`
  - `MODELS: dict[str, Model]` с ключами `"cudy_wbr3000uax-v1"` (tested=True) и `"cudy_wr3000s-v1"` (tested=False)
  - `find_model(board: str) -> Model | None`

- [ ] **Step 1: Написать падающий тест**

```python
# station/tests/test_models.py
from station.models import MODELS, find_model

def test_known_boards_present():
    assert find_model("cudy,wbr3000uax-v1").key == "cudy_wbr3000uax-v1"
    assert find_model("cudy,wr3000s-v1").key == "cudy_wr3000s-v1"

def test_unknown_board_returns_none():
    assert find_model("cudy,wr3000-v1") is None  # 16 МБ — намеренно не поддержан

def test_wbr3000uax_is_tested_wr3000s_is_not():
    assert MODELS["cudy_wbr3000uax-v1"].tested is True
    assert MODELS["cudy_wr3000s-v1"].tested is False

def test_version_pinned_and_thirdparty_hashes_present():
    m = MODELS["cudy_wbr3000uax-v1"]
    assert m.openwrt_version == "25.12.4"
    assert len(m.mtd_rw.sha256) == 64
    assert len(m.settings_backup.sha256) == 64
    assert {a.kind for a in m.artifacts} == {"preloader", "fip", "recovery", "sysupgrade"}
```

- [ ] **Step 2: Запустить, убедиться что падает**

Run: `python -m pytest station/tests/test_models.py -v`
Expected: FAIL, `ModuleNotFoundError: No module named 'station'`

- [ ] **Step 3: Написать модуль**

`station/__init__.py` — пустой. `station/models.py`:

```python
from dataclasses import dataclass

@dataclass(frozen=True)
class Artifact:
    kind: str        # preloader | fip | recovery | sysupgrade
    filename: str
    sha256: str | None = None  # заполняется из sha256sums при загрузке

@dataclass(frozen=True)
class ThirdPartyFile:
    name: str
    sha256: str
    size: int

@dataclass(frozen=True)
class Model:
    key: str
    board: str
    openwrt_version: str
    stock_ip: str
    flash_mb: int
    tested: bool
    artifacts: tuple[Artifact, ...]
    settings_backup: ThirdPartyFile
    mtd_rw: ThirdPartyFile
    known_stock_versions: tuple[str, ...]

_V = "25.12.4"
_MTK = "openwrt-%s-mediatek-filogic-%s-ubootmod-%s"

def _artifacts(board: str) -> tuple[Artifact, ...]:
    return (
        Artifact("preloader", _MTK % (_V, board, "preloader.bin")),
        Artifact("fip", _MTK % (_V, board, "bl31-uboot.fip")),
        Artifact("recovery", _MTK % (_V, board, "initramfs-recovery.itb")),
        Artifact("sysupgrade", _MTK % (_V, board, "squashfs-sysupgrade.itb")),
    )

_MTD_RW = ThirdPartyFile(
    "mtd-rw.ko",
    "1ad25a1ea33a9467aa4e0db87647a0b16e125b79bf1c5241f67f5d050e026787",
    5320,
)

MODELS: dict[str, Model] = {
    "cudy_wbr3000uax-v1": Model(
        key="cudy_wbr3000uax-v1", board="cudy_wbr3000uax-v1",
        openwrt_version=_V, stock_ip="192.168.10.1", flash_mb=128, tested=True,
        artifacts=_artifacts("cudy_wbr3000uax-v1"),
        settings_backup=ThirdPartyFile(
            "settings_v2_@keeneticported.bin",
            "df725c26662321f0b65cfab26197634cef76629fc124b69eb49d436c309a0e66",
            23334),
        mtd_rw=_MTD_RW, known_stock_versions=(),
    ),
    "cudy_wr3000s-v1": Model(
        key="cudy_wr3000s-v1", board="cudy_wr3000s-v1",
        openwrt_version=_V, stock_ip="192.168.10.1", flash_mb=128, tested=False,
        artifacts=_artifacts("cudy_wr3000s-v1"),
        settings_backup=ThirdPartyFile(
            "settings_v2_@keeneticported.bin",
            "df725c26662321f0b65cfab26197634cef76629fc124b69eb49d436c309a0e66",
            23334),
        mtd_rw=_MTD_RW, known_stock_versions=(),
    ),
}

def find_model(board: str) -> Model | None:
    key = board.replace(",", "_")
    return MODELS.get(key)
```

- [ ] **Step 4: Запустить, убедиться что проходит**

Run: `python -m pytest station/tests/test_models.py -v`
Expected: PASS (4 passed)

- [ ] **Step 5: Коммит**

```bash
git add station/__init__.py station/models.py station/tests/test_models.py
git commit -m "feat(station): каркас пакета и описания моделей Cudy"
```

---

### Task 2: Скачивание и сверка официальных файлов

**Files:**
- Create: `station/artifacts.py`
- Test: `station/tests/test_artifacts.py`

**Interfaces:**
- Consumes: `Model`, `Artifact` из `station.models`
- Produces:
  - `class ArtifactError(Exception)`
  - `parse_sha256sums(text: str) -> dict[str, str]` — карта `имя_файла -> sha256`, разбирает строки вида `<hash> *<name>`
  - `sha256_file(path: pathlib.Path) -> str`
  - `ensure_artifacts(model: Model, cache_dir: pathlib.Path, fetch: Callable[[str], bytes]) -> dict[str, pathlib.Path]` — качает недостающее через `fetch(url)`, кладёт в `cache_dir`, сверяет с `sha256sums`; возвращает `kind -> путь`; при несовпадении бросает `ArtifactError`. `fetch` внедряется, чтобы тест не ходил в сеть.

- [ ] **Step 1: Написать падающий тест**

```python
# station/tests/test_artifacts.py
import hashlib, pathlib, pytest
from station.models import MODELS
from station.artifacts import parse_sha256sums, ensure_artifacts, ArtifactError

def test_parse_sha256sums():
    text = "abc123 *openwrt-file-one.itb\ndef456 *openwrt-file-two.bin\n"
    got = parse_sha256sums(text)
    assert got["openwrt-file-one.itb"] == "abc123"
    assert got["openwrt-file-two.bin"] == "def456"

def _fake_repo(model):
    blobs = {a.filename: (a.filename.encode() + b"-body") for a in model.artifacts}
    sums = "".join(f"{hashlib.sha256(v).hexdigest()} *{k}\n" for k, v in blobs.items())
    def fetch(url):
        name = url.rsplit("/", 1)[1]
        if name == "sha256sums":
            return sums.encode()
        return blobs[name]
    return fetch, blobs

def test_ensure_downloads_and_verifies(tmp_path):
    model = MODELS["cudy_wbr3000uax-v1"]
    fetch, blobs = _fake_repo(model)
    paths = ensure_artifacts(model, tmp_path, fetch)
    assert set(paths) == {"preloader", "fip", "recovery", "sysupgrade"}
    assert paths["fip"].read_bytes() == blobs[
        [a.filename for a in model.artifacts if a.kind == "fip"][0]]

def test_ensure_rejects_tampered_file(tmp_path):
    model = MODELS["cudy_wbr3000uax-v1"]
    fetch, blobs = _fake_repo(model)
    def bad_fetch(url):
        if url.endswith("sha256sums"):
            return fetch(url)
        return fetch(url) + b"tampered"
    with pytest.raises(ArtifactError):
        ensure_artifacts(model, tmp_path, bad_fetch)
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
    for line in text.splitlines():
        line = line.strip()
        if not line:
            continue
        digest, _, name = line.partition(" ")
        out[name.lstrip("*").strip()] = digest.strip()
    return out

def sha256_file(path: pathlib.Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as f:
        for chunk in iter(lambda: f.read(65536), b""):
            h.update(chunk)
    return h.hexdigest()

def ensure_artifacts(model: Model, cache_dir: pathlib.Path,
                     fetch: Callable[[str], bytes]) -> dict[str, pathlib.Path]:
    cache_dir.mkdir(parents=True, exist_ok=True)
    base = BASE.format(v=model.openwrt_version)
    sums = parse_sha256sums(fetch(base + "sha256sums").decode("utf-8", "replace"))
    paths = {}
    for art in model.artifacts:
        want = sums.get(art.filename)
        if not want:
            raise ArtifactError(f"{art.filename} отсутствует в sha256sums")
        dest = cache_dir / art.filename
        if not dest.exists() or sha256_file(dest) != want:
            dest.write_bytes(fetch(base + art.filename))
        got = sha256_file(dest)
        if got != want:
            raise ArtifactError(
                f"{art.filename}: сумма {got} не совпала с официальной {want}")
        paths[art.kind] = dest
    return paths
```

- [ ] **Step 4: Запустить, убедиться что проходит**

Run: `python -m pytest station/tests/test_artifacts.py -v`
Expected: PASS (4 passed)

- [ ] **Step 5: Коммит**

```bash
git add station/artifacts.py station/tests/test_artifacts.py
git commit -m "feat(station): загрузка и сверка официальных образов OpenWrt"
```

---

### Task 3: Сторонние файлы из локального каталога

**Files:**
- Create: `station/thirdparty.py`
- Test: `station/tests/test_thirdparty.py`

**Interfaces:**
- Consumes: `ThirdPartyFile` из `station.models`, `sha256_file`, `ArtifactError` из `station.artifacts`
- Produces: `load_thirdparty(spec: ThirdPartyFile, assets_dir: pathlib.Path) -> pathlib.Path` — проверяет существование, размер и sha256; при отсутствии файла бросает `ArtifactError` с указанием, что положить в `assets_dir`; при неверной сумме — тоже `ArtifactError`.

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

def test_missing_file_explains(tmp_path):
    with pytest.raises(ArtifactError) as e:
        load_thirdparty(_spec(b"x"), tmp_path)
    assert "mtd-rw.ko" in str(e.value)

def test_wrong_hash_rejected(tmp_path):
    (tmp_path / "mtd-rw.ko").write_bytes(b"different")
    with pytest.raises(ArtifactError):
        load_thirdparty(_spec(b"expected"), tmp_path)
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

def load_thirdparty(spec: ThirdPartyFile, assets_dir: pathlib.Path) -> pathlib.Path:
    path = assets_dir / spec.name
    if not path.exists():
        raise ArtifactError(
            f"Нет файла {spec.name}. Положите его в {assets_dir} "
            f"(ожидается размер {spec.size} байт).")
    if path.stat().st_size != spec.size:
        raise ArtifactError(
            f"{spec.name}: размер {path.stat().st_size} вместо {spec.size}")
    got = sha256_file(path)
    if got != spec.sha256:
        raise ArtifactError(
            f"{spec.name}: сумма {got} не совпала с ожидаемой {spec.sha256}")
    return path
```

- [ ] **Step 4: Запустить, убедиться что проходит**

Run: `python -m pytest station/tests/test_thirdparty.py -v`
Expected: PASS (3 passed)

- [ ] **Step 5: Коммит**

```bash
git add station/thirdparty.py station/tests/test_thirdparty.py
git commit -m "feat(station): сторонние файлы из локального каталога по sha256"
```

---

### Task 4: Разбор /proc/mtd и границы Remote

**Files:**
- Create: `station/remote.py` (пока только протокол `Remote` и `FakeRemote` для тестов)
- Create: `station/mtd.py`
- Test: `station/tests/test_mtd.py`

**Interfaces:**
- Produces в `station/remote.py`:
  - `class Remote(Protocol)` с методами `run(cmd: str) -> tuple[int, bytes]`, `upload(data: bytes, dest: str) -> None`, `read(path: str, size: int | None = None) -> bytes`
  - `class FakeRemote` — реализация для тестов: принимает `files: dict[str, bytes]` (изображает разделы) и `responses: dict[str, tuple[int, bytes]]` (ответы на команды); `read` отдаёт из `files`, `upload` пишет в отдельный `uploaded: dict`, `run` — из `responses`
- Produces в `station/mtd.py`:
  - `@dataclass(frozen=True) Partition(dev: str, name: str, size: int)`
  - `parse_proc_mtd(text: str) -> list[Partition]`
  - `find_partition(parts, name) -> Partition` (бросает `KeyError` при отсутствии)

- [ ] **Step 1: Написать падающий тест**

```python
# station/tests/test_mtd.py
import pytest
from station.mtd import parse_proc_mtd, find_partition

SAMPLE = (
    'dev:    size   erasesize  name\n'
    'mtd0: 00100000 00020000 "BL2"\n'
    'mtd1: 00040000 00020000 "u-boot-env"\n'
    'mtd4: 00080000 00020000 "FIP"\n'
    'mtd5: 07800000 00020000 "ubi"\n'
)

def test_parse_lists_all_partitions():
    parts = parse_proc_mtd(SAMPLE)
    assert [p.name for p in parts] == ["BL2", "u-boot-env", "FIP", "ubi"]
    assert find_partition(parts, "ubi").dev == "/dev/mtd5"
    assert find_partition(parts, "FIP").size == 0x80000

def test_missing_partition_raises():
    with pytest.raises(KeyError):
        find_partition(parse_proc_mtd(SAMPLE), "Factory")
```

- [ ] **Step 2: Запустить, убедиться что падает**

Run: `python -m pytest station/tests/test_mtd.py -v`
Expected: FAIL, `ModuleNotFoundError`

- [ ] **Step 3: Написать модули**

```python
# station/remote.py
from typing import Protocol

class Remote(Protocol):
    def run(self, cmd: str) -> tuple[int, bytes]: ...
    def upload(self, data: bytes, dest: str) -> None: ...
    def read(self, path: str, size: int | None = None) -> bytes: ...

class FakeRemote:
    def __init__(self, files=None, responses=None):
        self.files = dict(files or {})
        self.responses = dict(responses or {})
        self.uploaded: dict[str, bytes] = {}
        self.commands: list[str] = []
    def run(self, cmd):
        self.commands.append(cmd)
        return self.responses.get(cmd, (0, b""))
    def upload(self, data, dest):
        self.uploaded[dest] = data
    def read(self, path, size=None):
        data = self.files[path]
        return data[:size] if size else data
```

```python
# station/mtd.py
import re
from dataclasses import dataclass

@dataclass(frozen=True)
class Partition:
    dev: str
    name: str
    size: int

_LINE = re.compile(r'^(mtd\d+):\s+([0-9a-f]+)\s+[0-9a-f]+\s+"([^"]*)"')

def parse_proc_mtd(text: str) -> list[Partition]:
    parts = []
    for line in text.splitlines():
        m = _LINE.match(line.strip())
        if m:
            parts.append(Partition(f"/dev/{m.group(1)}", m.group(3), int(m.group(2), 16)))
    return parts

def find_partition(parts: list[Partition], name: str) -> Partition:
    for p in parts:
        if p.name == name:
            return p
    raise KeyError(name)
```

- [ ] **Step 4: Запустить, убедиться что проходит**

Run: `python -m pytest station/tests/test_mtd.py -v`
Expected: PASS (2 passed)

- [ ] **Step 5: Коммит**

```bash
git add station/remote.py station/mtd.py station/tests/test_mtd.py
git commit -m "feat(station): разбор /proc/mtd и граница Remote с фейком"
```

---

### Task 5: Копии разделов с двойным чтением

**Files:**
- Modify: `station/mtd.py`
- Test: `station/tests/test_mtd_backup.py`

**Interfaces:**
- Consumes: `Remote`, `FakeRemote`, `Partition`, `parse_proc_mtd`
- Produces:
  - `class MtdError(Exception)`
  - `read_partitions(remote: Remote) -> list[Partition]` — вызывает `remote.run("cat /proc/mtd")`, разбирает вывод
  - `backup_partition(remote, part, dest_dir) -> pathlib.Path` — читает раздел дважды через `remote.read(part.dev)`, сравнивает; при расхождении бросает `MtdError`; при совпадении пишет в `dest_dir/<name>.bin` и возвращает путь
  - `backup_all(remote, parts, dest_dir, skip=("ubi",)) -> dict[str, pathlib.Path]`

- [ ] **Step 1: Написать падающий тест**

```python
# station/tests/test_mtd_backup.py
import pytest
from station.remote import FakeRemote
from station.mtd import read_partitions, backup_partition, backup_all, find_partition, MtdError

PROC = (0, b'dev:    size   erasesize  name\n'
           b'mtd0: 00100000 00020000 "BL2"\n'
           b'mtd3: 00080000 00020000 "Factory"\n'
           b'mtd5: 07800000 00020000 "ubi"\n')

def test_read_partitions_uses_proc_mtd():
    r = FakeRemote(responses={"cat /proc/mtd": PROC})
    assert find_partition(read_partitions(r), "Factory").dev == "/dev/mtd3"

def test_backup_ok_when_two_reads_match(tmp_path):
    r = FakeRemote(responses={"cat /proc/mtd": PROC}, files={"/dev/mtd3": b"factory-bytes"})
    part = find_partition(read_partitions(r), "Factory")
    path = backup_partition(r, part, tmp_path)
    assert path.read_bytes() == b"factory-bytes"

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
    with pytest.raises(MtdError):
        backup_partition(r, part, tmp_path)

def test_backup_all_skips_ubi(tmp_path):
    r = FakeRemote(responses={"cat /proc/mtd": PROC},
                   files={"/dev/mtd0": b"bl2", "/dev/mtd3": b"fac", "/dev/mtd5": b"ubi"})
    got = backup_all(r, read_partitions(r), tmp_path)
    assert set(got) == {"BL2", "Factory"}
```

- [ ] **Step 2: Запустить, убедиться что падает**

Run: `python -m pytest station/tests/test_mtd_backup.py -v`
Expected: FAIL, `ImportError: cannot import name 'read_partitions'`

- [ ] **Step 3: Дописать в `station/mtd.py`**

```python
import pathlib

class MtdError(Exception):
    pass

def read_partitions(remote) -> list[Partition]:
    code, out = remote.run("cat /proc/mtd")
    if code != 0:
        raise MtdError("не удалось прочитать /proc/mtd")
    return parse_proc_mtd(out.decode("utf-8", "replace"))

def backup_partition(remote, part: Partition, dest_dir: pathlib.Path) -> pathlib.Path:
    first = remote.read(part.dev)
    second = remote.read(part.dev)
    if first != second:
        raise MtdError(f"{part.name}: два чтения раздела не совпали")
    dest_dir.mkdir(parents=True, exist_ok=True)
    dest = dest_dir / f"{part.name}.bin"
    dest.write_bytes(first)
    return dest

def backup_all(remote, parts, dest_dir, skip=("ubi",)) -> dict[str, pathlib.Path]:
    out = {}
    for p in parts:
        if p.name in skip:
            continue
        out[p.name] = backup_partition(remote, p, dest_dir)
    return out
```

- [ ] **Step 4: Запустить, убедиться что проходит**

Run: `python -m pytest station/tests/test_mtd_backup.py -v`
Expected: PASS (4 passed)

- [ ] **Step 5: Коммит**

```bash
git add station/mtd.py station/tests/test_mtd_backup.py
git commit -m "feat(station): копии разделов с двойным чтением, ubi пропускается"
```

---

### Task 6: Запись загрузчика с обратным чтением

**Files:**
- Modify: `station/mtd.py`
- Test: `station/tests/test_mtd_write.py`

**Interfaces:**
- Consumes: `Remote`, `Partition`, `find_partition`, `MtdError`, `sha256_file`
- Produces:
  - `insmod_mtd_rw(remote) -> None` — заливает уже загруженный модуль (путь `/tmp/mtd-rw.ko`) и `insmod`; ошибка → `MtdError`
  - `write_and_verify(remote, part, local_file, tmp_name) -> None` — заливает файл в `/tmp/<tmp_name>`, сверяет sha256 на роутере (`sha256sum`), пишет `mtd write`, читает обратно первые `len(file)` байт через `remote.read(part.dev, size)`, сравнивает; любое расхождение → `MtdError` (без перезагрузки)

- [ ] **Step 1: Написать падающий тест**

```python
# station/tests/test_mtd_write.py
import hashlib, pathlib, pytest
from station.remote import FakeRemote
from station.mtd import Partition, write_and_verify, MtdError

def _remote_with(part_dev, body):
    digest = hashlib.sha256(body).hexdigest()
    r = FakeRemote(
        responses={f"sha256sum /tmp/fip.bin": (0, f"{digest}  /tmp/fip.bin\n".encode()),
                   f"mtd write /tmp/fip.bin FIP": (0, b"")},
        files={part_dev: body})
    return r

def test_write_ok_when_readback_matches(tmp_path):
    body = b"fip-image-body"
    f = tmp_path / "fip.bin"; f.write_bytes(body)
    part = Partition("/dev/mtd4", "FIP", len(body))
    r = _remote_with("/dev/mtd4", body)
    write_and_verify(r, part, f, "fip.bin")  # не бросает
    assert r.uploaded["/tmp/fip.bin"] == body

def test_write_fails_on_hash_mismatch_on_router(tmp_path):
    body = b"fip-image-body"
    f = tmp_path / "fip.bin"; f.write_bytes(body)
    part = Partition("/dev/mtd4", "FIP", len(body))
    r = _remote_with("/dev/mtd4", body)
    r.responses["sha256sum /tmp/fip.bin"] = (0, b"deadbeef  /tmp/fip.bin\n")
    with pytest.raises(MtdError):
        write_and_verify(r, part, f, "fip.bin")

def test_write_fails_when_readback_differs(tmp_path):
    body = b"fip-image-body"
    f = tmp_path / "fip.bin"; f.write_bytes(body)
    part = Partition("/dev/mtd4", "FIP", len(body))
    r = _remote_with("/dev/mtd4", body)
    r.files["/dev/mtd4"] = b"something-else!"
    with pytest.raises(MtdError):
        write_and_verify(r, part, f, "fip.bin")
```

- [ ] **Step 2: Запустить, убедиться что падает**

Run: `python -m pytest station/tests/test_mtd_write.py -v`
Expected: FAIL, `ImportError: cannot import name 'write_and_verify'`

- [ ] **Step 3: Дописать в `station/mtd.py`**

```python
from .artifacts import sha256_file

def insmod_mtd_rw(remote) -> None:
    code, out = remote.run(
        "insmod /tmp/mtd-rw.ko i_want_a_brick=1 || "
        "insmod /tmp/mtd-rw.ko")
    if code != 0:
        raise MtdError(f"insmod mtd-rw не удался: {out.decode('utf-8','replace')}")

def write_and_verify(remote, part: Partition, local_file, tmp_name: str) -> None:
    data = pathlib.Path(local_file).read_bytes()
    tmp = f"/tmp/{tmp_name}"
    remote.upload(data, tmp)
    want = sha256_file(pathlib.Path(local_file))
    code, out = remote.run(f"sha256sum {tmp}")
    got = out.decode("utf-8", "replace").split()[0] if code == 0 else ""
    if got != want:
        raise MtdError(f"{tmp}: сумма на роутере {got} != {want}")
    code, out = remote.run(f"mtd write {tmp} {part.name}")
    if code != 0:
        raise MtdError(f"mtd write {part.name}: {out.decode('utf-8','replace')}")
    back = remote.read(part.dev, len(data))
    if back != data:
        raise MtdError(f"{part.name}: обратное чтение не совпало с записанным")
```

- [ ] **Step 4: Запустить, убедиться что проходит**

Run: `python -m pytest station/tests/test_mtd_write.py -v`
Expected: PASS (3 passed)

- [ ] **Step 5: Коммит**

```bash
git add station/mtd.py station/tests/test_mtd_write.py
git commit -m "feat(station): запись загрузчика со сверкой суммы и обратным чтением"
```

---

### Task 7: Мини-сервер TFTP только на чтение

**Files:**
- Create: `station/tftp.py`
- Test: `station/tests/test_tftp.py`

**Interfaces:**
- Produces:
  - `class TftpError(Exception)`
  - `class ReadOnlyTftp` — конструктор `(filename: str, data: bytes, host="0.0.0.0", port=69)`; методы `start()` (поднимает UDP-поток), `stop()`, свойство `served: bool` (отдал ли файл целиком); отвечает только на RRQ ровно этого `filename` в режиме `octet`, на запрос другого имени и на WRQ шлёт TFTP-ошибку
  - `parse_rrq(packet: bytes) -> tuple[str, str]` — возвращает `(filename, mode)`; для не-RRQ бросает `TftpError`

- [ ] **Step 1: Написать падающий тест**

```python
# station/tests/test_tftp.py
import socket, struct, pytest
from station.tftp import ReadOnlyTftp, parse_rrq, TftpError

def test_parse_rrq():
    pkt = b"\x00\x01" + b"file.itb\x00octet\x00"
    assert parse_rrq(pkt) == ("file.itb", "octet")

def test_parse_rejects_wrq():
    with pytest.raises(TftpError):
        parse_rrq(b"\x00\x02file\x00octet\x00")

def _fetch(port, name, blocks=None):
    # минимальный TFTP-клиент поверх стандартной библиотеки
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM); s.settimeout(3)
    s.sendto(b"\x00\x01" + name.encode() + b"\x00octet\x00", ("127.0.0.1", port))
    got = b""; expect = 1
    while True:
        data, addr = s.recvfrom(1024)
        op = struct.unpack("!H", data[:2])[0]
        if op == 5:  # ERROR
            s.close(); raise AssertionError("tftp error")
        blk = struct.unpack("!H", data[2:4])[0]
        got += data[4:]
        s.sendto(b"\x00\x04" + struct.pack("!H", blk), addr)
        if len(data[4:]) < 512:
            break
        expect += 1
    s.close(); return got

def test_serves_exact_file():
    body = b"A" * 1100
    srv = ReadOnlyTftp("recovery.itb", body, host="127.0.0.1", port=0)
    srv.start()
    try:
        assert _fetch(srv.port, "recovery.itb") == body
        assert srv.served is True
    finally:
        srv.stop()

def test_refuses_other_name():
    srv = ReadOnlyTftp("recovery.itb", b"x", host="127.0.0.1", port=0)
    srv.start()
    try:
        with pytest.raises(AssertionError):
            _fetch(srv.port, "other.itb")
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
    return parts[0].decode("latin1"), parts[1].decode("latin1").lower()

class ReadOnlyTftp:
    def __init__(self, filename, data, host="0.0.0.0", port=69):
        self.filename = filename
        self.data = data
        self.host = host
        self._want_port = port
        self.port = port
        self.served = False
        self._sock = None
        self._thread = None
        self._stop = threading.Event()

    def start(self):
        self._sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        self._sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        self._sock.bind((self.host, self._want_port))
        self.port = self._sock.getsockname()[1]
        self._sock.settimeout(0.5)
        self._thread = threading.Thread(target=self._run, daemon=True)
        self._thread.start()

    def stop(self):
        self._stop.set()
        if self._thread:
            self._thread.join(timeout=2)
        if self._sock:
            self._sock.close()

    def _err(self, addr, msg):
        self._sock.sendto(b"\x00\x05\x00\x00" + msg.encode() + b"\x00", addr)

    def _run(self):
        while not self._stop.is_set():
            try:
                packet, addr = self._sock.recvfrom(1024)
            except socket.timeout:
                continue
            if packet[:2] == b"\x00\x02":
                self._err(addr, "read-only")
                continue
            try:
                name, mode = parse_rrq(packet)
            except TftpError:
                continue
            if name != self.filename or mode != "octet":
                self._err(addr, "not found")
                continue
            self._send_file(addr)

    def _send_file(self, addr):
        blocks = [self.data[i:i + 512] for i in range(0, len(self.data) + 1, 512)] or [b""]
        if len(self.data) % 512 == 0:
            blocks.append(b"")  # завершающий пустой блок
        for i, chunk in enumerate(blocks, start=1):
            pkt = b"\x00\x03" + struct.pack("!H", i & 0xFFFF) + chunk
            for _ in range(5):
                self._sock.sendto(pkt, addr)
                try:
                    ack, _ = self._sock.recvfrom(1024)
                except socket.timeout:
                    continue
                if ack[:2] == b"\x00\x04" and struct.unpack("!H", ack[2:4])[0] == (i & 0xFFFF):
                    break
            else:
                return
        self.served = True
```

- [ ] **Step 4: Запустить, убедиться что проходит**

Run: `python -m pytest station/tests/test_tftp.py -v`
Expected: PASS (4 passed)

- [ ] **Step 5: Коммит**

```bash
git add station/tftp.py station/tests/test_tftp.py
git commit -m "feat(station): мини-сервер TFTP только на чтение одного файла"
```

---

### Task 8: Проверка сети под три ОС

**Files:**
- Create: `station/network.py`
- Test: `station/tests/test_network.py`

**Interfaces:**
- Produces:
  - `parse_addresses(os_name: str, output: str) -> set[str]` — вытаскивает IPv4 из вывода `ifconfig` (macOS), `ip addr` (Linux), `ipconfig` (Windows)
  - `check_ready(addresses: set[str]) -> list[str]` — возвращает список недостающего: нужен адрес в `192.168.10.0/24` для входа и `192.168.1.254` для TFTP; пустой список = всё готово
  - `setup_command(os_name: str, iface: str) -> str` — строка-подсказка, как назначить `192.168.1.254/24`

- [ ] **Step 1: Написать падающий тест**

```python
# station/tests/test_network.py
from station.network import parse_addresses, check_ready, setup_command

LINUX = "2: eth0: <BROADCAST> ...\n    inet 192.168.10.5/24 brd ...\n"
MAC = "en0: flags=8863\n\tinet 192.168.1.254 netmask 0xffffff00\n"
WIN = "   IPv4 Address. . . . . . . . . . . : 192.168.10.7\n"

def test_parse_linux_mac_win():
    assert "192.168.10.5" in parse_addresses("linux", LINUX)
    assert "192.168.1.254" in parse_addresses("darwin", MAC)
    assert "192.168.10.7" in parse_addresses("windows", WIN)

def test_check_ready_reports_missing():
    missing = check_ready({"192.168.10.5"})
    assert any("192.168.1.254" in m for m in missing)
    assert check_ready({"192.168.10.5", "192.168.1.254"}) == []

def test_setup_command_mentions_iface_and_ip():
    cmd = setup_command("linux", "eth0")
    assert "eth0" in cmd and "192.168.1.254" in cmd
```

- [ ] **Step 2: Запустить, убедиться что падает**

Run: `python -m pytest station/tests/test_network.py -v`
Expected: FAIL, `ModuleNotFoundError`

- [ ] **Step 3: Написать модуль**

```python
# station/network.py
import ipaddress, re

_IPV4 = re.compile(r'(\d{1,3}(?:\.\d{1,3}){3})')

def parse_addresses(os_name: str, output: str) -> set[str]:
    found = set()
    for m in _IPV4.finditer(output):
        try:
            ipaddress.IPv4Address(m.group(1))
        except ValueError:
            continue
        found.add(m.group(1))
    return found

def check_ready(addresses: set[str]) -> list[str]:
    missing = []
    net = ipaddress.ip_network("192.168.10.0/24")
    if not any(ipaddress.IPv4Address(a) in net for a in addresses):
        missing.append("нет адреса в 192.168.10.0/24 (вход в заводской роутер)")
    if "192.168.1.254" not in addresses:
        missing.append("нет адреса 192.168.1.254 (нужен для TFTP-восстановления)")
    return missing

def setup_command(os_name: str, iface: str) -> str:
    o = os_name.lower()
    if o.startswith("darwin") or o == "mac":
        return f"sudo ifconfig {iface} alias 192.168.1.254 255.255.255.0"
    if o.startswith("win"):
        return (f'netsh interface ip add address "{iface}" '
                f'192.168.1.254 255.255.255.0')
    return f"sudo ip addr add 192.168.1.254/24 dev {iface}"
```

- [ ] **Step 4: Запустить, убедиться что проходит**

Run: `python -m pytest station/tests/test_network.py -v`
Expected: PASS (3 passed)

- [ ] **Step 5: Коммит**

```bash
git add station/network.py station/tests/test_network.py
git commit -m "feat(station): проверка адресов интерфейса под macOS, Linux, Windows"
```

---

### Task 9: Паспорт роутера

**Files:**
- Create: `station/passport.py`
- Test: `station/tests/test_passport.py`

**Interfaces:**
- Produces:
  - `@dataclass Passport(model, revision, serial, macs, stock_version, openwrt_version, written_sha256, steps, station_version)` с методом `to_dict()`
  - `save_passport(passport, device_dir) -> pathlib.Path` — пишет `passport.json` (UTF-8, `ensure_ascii=False`, отступы), возвращает путь
  - `record_step(device_dir, name, outcome) -> None` — дописывает шаг с меткой времени в `state.json`
  - `load_state(device_dir) -> dict` — читает `state.json` или `{}`

- [ ] **Step 1: Написать падающий тест**

```python
# station/tests/test_passport.py
import json
from station.passport import Passport, save_passport, record_step, load_state

def test_save_passport_roundtrip(tmp_path):
    p = Passport(model="cudy_wbr3000uax-v1", revision="v1", serial="SN123",
                 macs=["AA:BB:CC:00:11:22"], stock_version="1.2.3",
                 openwrt_version="25.12.4", written_sha256={"fip": "abc"},
                 steps=[], station_version="0.1.0")
    path = save_passport(p, tmp_path)
    data = json.loads(path.read_text(encoding="utf-8"))
    assert data["serial"] == "SN123"
    assert data["written_sha256"]["fip"] == "abc"

def test_state_accumulates_steps(tmp_path):
    record_step(tmp_path, "backup", "ok")
    record_step(tmp_path, "write_bootloader", "ok")
    state = load_state(tmp_path)
    assert [s["name"] for s in state["steps"]] == ["backup", "write_bootloader"]

def test_load_state_empty(tmp_path):
    assert load_state(tmp_path) == {}
```

- [ ] **Step 2: Запустить, убедиться что падает**

Run: `python -m pytest station/tests/test_passport.py -v`
Expected: FAIL, `ModuleNotFoundError`

- [ ] **Step 3: Написать модуль**

```python
# station/passport.py
import json, pathlib, time
from dataclasses import dataclass, field, asdict

@dataclass
class Passport:
    model: str
    revision: str
    serial: str
    macs: list
    stock_version: str
    openwrt_version: str
    written_sha256: dict
    steps: list
    station_version: str
    def to_dict(self):
        return asdict(self)

def save_passport(passport: Passport, device_dir: pathlib.Path) -> pathlib.Path:
    device_dir.mkdir(parents=True, exist_ok=True)
    path = device_dir / "passport.json"
    path.write_text(json.dumps(passport.to_dict(), ensure_ascii=False, indent=2),
                    encoding="utf-8")
    return path

def load_state(device_dir: pathlib.Path) -> dict:
    path = device_dir / "state.json"
    if not path.exists():
        return {}
    return json.loads(path.read_text(encoding="utf-8"))

def record_step(device_dir: pathlib.Path, name: str, outcome: str) -> None:
    device_dir.mkdir(parents=True, exist_ok=True)
    state = load_state(device_dir)
    state.setdefault("steps", []).append(
        {"name": name, "outcome": outcome, "at": time.time()})
    (device_dir / "state.json").write_text(
        json.dumps(state, ensure_ascii=False, indent=2), encoding="utf-8")
```

- [ ] **Step 4: Запустить, убедиться что проходит**

Run: `python -m pytest station/tests/test_passport.py -v`
Expected: PASS (3 passed)

- [ ] **Step 5: Коммит**

```bash
git add station/passport.py station/tests/test_passport.py
git commit -m "feat(station): паспорт роутера и журнал шагов с возобновлением"
```

---

### Task 10: Машина состояний потока

**Files:**
- Create: `station/flow.py`
- Test: `station/tests/test_flow.py`

**Interfaces:**
- Consumes: `record_step`, `load_state` из `station.passport`
- Produces:
  - `STEPS: tuple[str, ...]` — точный порядок: `("artifacts","network","identify","access","backup","write_bootloader","tftp_recovery","install","acceptance","passport")`
  - `next_step(device_dir) -> str | None` — первый неподтверждённый шаг по `state.json`; `None` если все пройдены
  - `run_flow(device_dir, handlers, *, resume=True) -> None` — идёт по `STEPS` начиная с `next_step` (или с начала при `resume=False`), на каждый шаг вызывает `handlers[step]()`; исключение прекращает поток, шаг не отмечается; после успеха вызывает `record_step(..., "ok")`
  - особый случай: если последний подтверждённый шаг `write_bootloader`, следующим идёт `tftp_recovery`, а не повтор записи (это уже обеспечивается тем, что `write_bootloader` отмечен `ok`)

- [ ] **Step 1: Написать падающий тест**

```python
# station/tests/test_flow.py
import pytest
from station.flow import STEPS, next_step, run_flow
from station.passport import record_step

def test_step_order():
    assert STEPS[0] == "artifacts"
    assert STEPS.index("backup") < STEPS.index("write_bootloader") < STEPS.index("tftp_recovery")
    assert STEPS[-1] == "passport"

def test_next_step_fresh(tmp_path):
    assert next_step(tmp_path) == "artifacts"

def test_next_step_after_bootloader_is_recovery(tmp_path):
    for s in STEPS[:STEPS.index("write_bootloader") + 1]:
        record_step(tmp_path, s, "ok")
    assert next_step(tmp_path) == "tftp_recovery"

def test_run_flow_stops_on_failure(tmp_path):
    calls = []
    def ok(name): return lambda: calls.append(name)
    def boom(): raise RuntimeError("fail")
    handlers = {s: ok(s) for s in STEPS}
    handlers["access"] = boom
    with pytest.raises(RuntimeError):
        run_flow(tmp_path, handlers)
    assert "identify" in calls and "backup" not in calls
    assert next_step(tmp_path) == "access"  # застряли на упавшем

def test_run_flow_resumes(tmp_path):
    calls = []
    handlers = {s: (lambda n=s: calls.append(n)) for s in STEPS}
    for s in STEPS[:3]:
        record_step(tmp_path, s, "ok")
    run_flow(tmp_path, handlers)
    assert calls == list(STEPS[3:])
```

- [ ] **Step 2: Запустить, убедиться что падает**

Run: `python -m pytest station/tests/test_flow.py -v`
Expected: FAIL, `ModuleNotFoundError`

- [ ] **Step 3: Написать модуль**

```python
# station/flow.py
import pathlib
from .passport import load_state, record_step

STEPS = ("artifacts", "network", "identify", "access", "backup",
         "write_bootloader", "tftp_recovery", "install", "acceptance", "passport")

def _done(device_dir) -> list[str]:
    return [s["name"] for s in load_state(device_dir).get("steps", [])
            if s.get("outcome") == "ok"]

def next_step(device_dir: pathlib.Path):
    done = set(_done(device_dir))
    for s in STEPS:
        if s not in done:
            return s
    return None

def run_flow(device_dir: pathlib.Path, handlers: dict, *, resume: bool = True) -> None:
    start = STEPS.index(next_step(device_dir)) if (resume and next_step(device_dir)) else 0
    if not resume:
        start = 0
    for step in STEPS[start:]:
        handlers[step]()
        record_step(device_dir, step, "ok")
```

- [ ] **Step 4: Запустить, убедиться что проходит**

Run: `python -m pytest station/tests/test_flow.py -v`
Expected: PASS (5 passed)

- [ ] **Step 5: Коммит**

```bash
git add station/flow.py station/tests/test_flow.py
git commit -m "feat(station): машина состояний потока с возобновлением"
```

---

### Task 11: SSH-реализация Remote (paramiko)

**Files:**
- Create: `station/ssh_remote.py`
- Create: `station/tests/test_ssh_remote.py`
- Modify: `pyproject.toml` (добавить зависимость `paramiko`)

**Interfaces:**
- Consumes: протокол `Remote`
- Produces:
  - `class SshRemote` с `__init__(host, user="root", password=None, port=22, connect_timeout=30)`, `connect()`, `close()`, и методами протокола `run`, `upload`, `read`
  - `read(path, size=None)` реализуется через `dd if=<path> bs=... count=...` при заданном `size`, иначе `cat`
  - `wait_for_ssh(host, user, passwords: list, timeout) -> SshRemote` — опрос до появления SSH; перебирает пароли-кандидаты (для recovery — пустой пароль)

- [ ] **Step 1: Написать тест на разбор, без сети**

Полноценный SSH мокать дорого; тестируем чистую логику `read` — построение команды.

```python
# station/tests/test_ssh_remote.py
from station.ssh_remote import build_read_command

def test_read_full_uses_cat():
    assert build_read_command("/dev/mtd3", None) == "cat /dev/mtd3"

def test_read_sized_uses_dd():
    cmd = build_read_command("/dev/mtd4", 1048576)
    assert "dd" in cmd and "/dev/mtd4" in cmd and "1048576" in cmd
```

- [ ] **Step 2: Запустить, убедиться что падает**

Run: `python -m pytest station/tests/test_ssh_remote.py -v`
Expected: FAIL, `ModuleNotFoundError`

- [ ] **Step 3: Написать модуль**

```python
# station/ssh_remote.py
import time

def build_read_command(path: str, size) -> str:
    if size is None:
        return f"cat {path}"
    return f"dd if={path} bs=1 count={size} 2>/dev/null"

class SshRemote:
    def __init__(self, host, user="root", password=None, port=22, connect_timeout=30):
        self.host, self.user, self.password = host, user, password
        self.port, self.connect_timeout = port, connect_timeout
        self._client = None

    def connect(self):
        import paramiko
        c = paramiko.SSHClient()
        c.set_missing_host_key_policy(paramiko.AutoAddPolicy())
        c.connect(self.host, port=self.port, username=self.user,
                  password=self.password, timeout=self.connect_timeout,
                  allow_agent=False, look_for_keys=False)
        self._client = c

    def close(self):
        if self._client:
            self._client.close()

    def run(self, cmd):
        stdin, stdout, stderr = self._client.exec_command(cmd)
        out = stdout.read() + stderr.read()
        code = stdout.channel.recv_exit_status()
        return code, out

    def upload(self, data, dest):
        sftp = self._client.open_sftp()
        try:
            with sftp.file(dest, "wb") as f:
                f.write(data)
        finally:
            sftp.close()

    def read(self, path, size=None):
        code, out = self.run(build_read_command(path, size))
        if code != 0:
            raise IOError(f"чтение {path} не удалось")
        return out

def wait_for_ssh(host, user, passwords, timeout=180):
    deadline = time.time() + timeout
    last = None
    while time.time() < deadline:
        for pw in passwords:
            r = SshRemote(host, user=user, password=pw, connect_timeout=5)
            try:
                r.connect()
                return r
            except Exception as e:  # noqa: BLE001 — опрос до готовности
                last = e
        time.sleep(3)
    raise TimeoutError(f"SSH на {host} не поднялся: {last}")
```

- [ ] **Step 4: Запустить, убедиться что проходит**

Run: `python -m pytest station/tests/test_ssh_remote.py -v`
Expected: PASS (2 passed)

- [ ] **Step 5: Коммит**

```bash
git add station/ssh_remote.py station/tests/test_ssh_remote.py pyproject.toml
git commit -m "feat(station): SSH-реализация Remote через paramiko"
```

---

### Task 12: Заводской веб-интерфейс (Playwright)

**Files:**
- Create: `station/stock_ui.py`
- Create: `station/tests/test_stock_ui.py`

**Interfaces:**
- Produces:
  - `@dataclass StockInfo(model_board: str, revision: str, firmware_version: str)`
  - `identify(page, stock_ip) -> StockInfo` — открывает интерфейс, читает модель и версию (селекторы вынесены в константы модуля, чтобы правились без правки логики)
  - `restore_backup(page, stock_ip, backup_path) -> None` — идёт в раздел резервной копии (`/cgi-bin/luci/admin/system/backup`), загружает файл, подтверждает
  - `parse_model_from_title(text: str) -> str` — чистая функция извлечения платы из строки статуса; её и тестируем

- [ ] **Step 1: Написать тест на чистую функцию**

```python
# station/tests/test_stock_ui.py
from station.stock_ui import parse_model_from_title

def test_parse_wbr():
    assert parse_model_from_title("Model: Cudy WBR3000UAX") == "cudy_wbr3000uax-v1"

def test_parse_wr3000s():
    assert parse_model_from_title("Cudy WR3000S ...") == "cudy_wr3000s-v1"

def test_parse_unknown_returns_empty():
    assert parse_model_from_title("Cudy WR3000 v1") == ""
```

- [ ] **Step 2: Запустить, убедиться что падает**

Run: `python -m pytest station/tests/test_stock_ui.py -v`
Expected: FAIL, `ModuleNotFoundError`

- [ ] **Step 3: Написать модуль**

```python
# station/stock_ui.py
from dataclasses import dataclass

LUCI = "http://{ip}/cgi-bin/luci/"
BACKUP = "http://{ip}/cgi-bin/luci/admin/system/backup"

@dataclass
class StockInfo:
    model_board: str
    revision: str
    firmware_version: str

def parse_model_from_title(text: str) -> str:
    t = text.upper()
    if "WBR3000UAX" in t:
        return "cudy_wbr3000uax-v1"
    if "WR3000S" in t:
        return "cudy_wr3000s-v1"
    return ""

def identify(page, stock_ip) -> StockInfo:
    page.goto(LUCI.format(ip=stock_ip))
    body = page.content()
    board = parse_model_from_title(body)
    # версия прошивки — из строки статуса; селектор вынесен, чтобы правился отдельно
    version = ""
    for sel in ("#cbi-status-firmware", ".cbi-value:has-text('Firmware')"):
        el = page.query_selector(sel)
        if el:
            version = el.inner_text().strip()
            break
    return StockInfo(model_board=board, revision="v1", firmware_version=version)

def restore_backup(page, stock_ip, backup_path) -> None:
    page.goto(BACKUP.format(ip=stock_ip))
    page.set_input_files("input[type='file']", str(backup_path))
    page.click("button:has-text('Upload'), input[name='cbid.backup.1.restore']")
    page.click("button:has-text('Proceed'), input[name='cbid.backup.1.proceed']")
```

- [ ] **Step 4: Запустить, убедиться что проходит**

Run: `python -m pytest station/tests/test_stock_ui.py -v`
Expected: PASS (3 passed)

- [ ] **Step 5: Коммит**

```bash
git add station/stock_ui.py station/tests/test_stock_ui.py
git commit -m "feat(station): вход в заводской веб-интерфейс и восстановление настроек"
```

---

### Task 13: Сборка команд роутера (install, ubi)

**Files:**
- Create: `station/commands.py`
- Test: `station/tests/test_commands.py`

**Interfaces:**
- Consumes: `Partition`, `find_partition` из `station.mtd`
- Produces:
  - `ubi_layout_commands(ubi_dev: str) -> list[str]` — точная последовательность переразметки
  - `sysupgrade_command(remote_path: str) -> str`
  - `free_space_kb(df_output: str, mount="/overlay") -> int` — разбирает вывод `df`
  - `acceptance_ok(board, version, free_kb, *, want_board, want_version, min_kb=40*1024) -> list[str]` — список несоответствий (пустой = приёмка пройдена)

- [ ] **Step 1: Написать падающий тест**

```python
# station/tests/test_commands.py
from station.commands import (ubi_layout_commands, sysupgrade_command,
                              free_space_kb, acceptance_ok)

def test_ubi_layout_uses_named_dev():
    cmds = ubi_layout_commands("/dev/mtd5")
    joined = " ".join(cmds)
    assert "ubiformat /dev/mtd5 -y" in joined
    assert "ubootenv" in joined and "ubootenv2" in joined

def test_sysupgrade_is_no_preserve():
    assert sysupgrade_command("/tmp/sysupgrade.itb") == "sysupgrade -n /tmp/sysupgrade.itb"

def test_free_space_parsing():
    df = ("Filesystem  1K-blocks  Used Available Use% Mounted on\n"
          "overlayfs:/overlay  102400  1024  101376  1% /overlay\n")
    assert free_space_kb(df) == 101376

def test_acceptance_flags_mismatch():
    bad = acceptance_ok("cudy_wr3000s-v1", "25.12.4", 5000,
                        want_board="cudy_wbr3000uax-v1", want_version="25.12.4")
    assert any("board" in b.lower() or "плат" in b.lower() for b in bad)
    assert any("мест" in b.lower() for b in bad)
    ok = acceptance_ok("cudy_wbr3000uax-v1", "25.12.4", 60000,
                       want_board="cudy_wbr3000uax-v1", want_version="25.12.4")
    assert ok == []
```

- [ ] **Step 2: Запустить, убедиться что падает**

Run: `python -m pytest station/tests/test_commands.py -v`
Expected: FAIL, `ModuleNotFoundError`

- [ ] **Step 3: Написать модуль**

```python
# station/commands.py
def ubi_layout_commands(ubi_dev: str) -> list[str]:
    return [
        f"ubidetach -p {ubi_dev} 2>/dev/null; true",
        f"ubiformat {ubi_dev} -y",
        f"ubiattach -p {ubi_dev}",
        "ubimkvol /dev/ubi0 -n 0 -N ubootenv -s 128KiB",
        "ubimkvol /dev/ubi0 -n 1 -N ubootenv2 -s 128KiB",
    ]

def sysupgrade_command(remote_path: str) -> str:
    return f"sysupgrade -n {remote_path}"

def free_space_kb(df_output: str, mount: str = "/overlay") -> int:
    for line in df_output.splitlines():
        if line.rstrip().endswith(mount):
            parts = line.split()
            return int(parts[3])
    raise ValueError(f"{mount} не найден в выводе df")

def acceptance_ok(board, version, free_kb, *, want_board, want_version,
                  min_kb=40 * 1024) -> list[str]:
    bad = []
    if board != want_board:
        bad.append(f"плата {board} вместо {want_board}")
    if version != want_version:
        bad.append(f"версия {version} вместо {want_version}")
    if free_kb < min_kb:
        bad.append(f"мало места: {free_kb} КБ < {min_kb} КБ")
    return bad
```

- [ ] **Step 4: Запустить, убедиться что проходит**

Run: `python -m pytest station/tests/test_commands.py -v`
Expected: PASS (4 passed)

- [ ] **Step 5: Коммит**

```bash
git add station/commands.py station/tests/test_commands.py
git commit -m "feat(station): команды переразметки, установки и приёмки"
```

---

### Task 14: Точка входа и сборка потока

**Files:**
- Create: `station/__main__.py`
- Create: `station/app.py`
- Test: `station/tests/test_app.py`

**Interfaces:**
- Consumes: всё выше
- Produces:
  - `build_handlers(ctx) -> dict[str, Callable]` — связывает шаги `STEPS` с реальными действиями, используя переданный `ctx` (объект с моделью, каталогами, фабрикой `Remote`, TFTP). Тестируется с поддельным `ctx`, что каждый шаг вызывает нужный модуль.
  - `main(argv) -> int` — разбор аргументов (`--iface`, `--model`, `--assets`, `--allow-untested`, `--no-resume`), запуск `run_flow`; отказ при `tested=False` без `--allow-untested`

- [ ] **Step 1: Написать падающий тест**

```python
# station/tests/test_app.py
import pytest
from station.app import main

def test_untested_model_requires_flag(tmp_path, monkeypatch):
    code = main(["--model", "cudy_wr3000s-v1", "--iface", "eth0",
                 "--assets", str(tmp_path), "--dry-run"])
    assert code != 0  # без --allow-untested отказ

def test_untested_model_allowed_with_flag(tmp_path):
    code = main(["--model", "cudy_wr3000s-v1", "--iface", "eth0",
                 "--assets", str(tmp_path), "--allow-untested", "--dry-run"])
    assert code == 0

def test_unknown_model_rejected(tmp_path):
    code = main(["--model", "cudy_wr3000-v1", "--iface", "eth0",
                 "--assets", str(tmp_path), "--dry-run"])
    assert code != 0
```

- [ ] **Step 2: Запустить, убедиться что падает**

Run: `python -m pytest station/tests/test_app.py -v`
Expected: FAIL, `ModuleNotFoundError`

- [ ] **Step 3: Написать модули**

`station/app.py` — разбор аргументов и `--dry-run`, который проверяет модель и флаги, но не трогает железо. `build_handlers` собирает шаги из готовых модулей. `station/__main__.py`:

```python
# station/__main__.py
import sys
from .app import main
sys.exit(main(sys.argv[1:]))
```

```python
# station/app.py
import argparse, pathlib, platform
from .models import MODELS

def main(argv) -> int:
    ap = argparse.ArgumentParser(prog="station")
    ap.add_argument("--model", required=True)
    ap.add_argument("--iface", required=True)
    ap.add_argument("--assets", default=str(pathlib.Path.home() / ".flashing-station" / "assets"))
    ap.add_argument("--allow-untested", action="store_true")
    ap.add_argument("--no-resume", action="store_true")
    ap.add_argument("--dry-run", action="store_true")
    args = ap.parse_args(argv)

    model = MODELS.get(args.model)
    if model is None:
        print(f"Неизвестная модель {args.model}. Известные: {', '.join(MODELS)}")
        return 2
    if not model.tested and not args.allow_untested:
        print(f"{model.key} не проверена на железе. "
              f"Повторите с --allow-untested, если готовы рискнуть.")
        return 3
    if args.dry_run:
        print(f"OK (dry-run): {model.key}, версия {model.openwrt_version}")
        return 0
    # реальный проход собирается в build_handlers + run_flow
    from .flow import run_flow
    from . import wiring
    ctx = wiring.make_context(model, args)
    run_flow(ctx.device_dir, wiring.build_handlers(ctx), resume=not args.no_resume)
    return 0
```

Для `--dry-run` модуль `wiring` не нужен; создать заглушку `station/wiring.py` с `make_context` и `build_handlers`, которые собирают реальные шаги (в этой задаче достаточно, чтобы импорт существовал; полная проводка — следующая задача).

- [ ] **Step 4: Запустить, убедиться что проходит**

Run: `python -m pytest station/tests/test_app.py -v`
Expected: PASS (3 passed)

- [ ] **Step 5: Коммит**

```bash
git add station/app.py station/__main__.py station/wiring.py station/tests/test_app.py
git commit -m "feat(station): точка входа, разбор аргументов, гейт непроверенной модели"
```

---

### Task 15: Проводка шагов и общий прогон тестов

**Files:**
- Modify: `station/wiring.py`
- Create: `station/tests/test_wiring.py`
- Modify: `.github/workflows/ci.yml`

**Interfaces:**
- Consumes: все модули
- Produces:
  - `@dataclass Context(model, args, device_dir, cache_dir, assets_dir, remote_factory, ...)`
  - `make_context(model, args) -> Context`
  - `build_handlers(ctx) -> dict[str, Callable]` — каждый шаг вызывает свой модуль; проверяется поддельным `ctx`, что вызовы идут в нужные модули и в нужном порядке через `run_flow`

- [ ] **Step 1: Написать падающий тест**

```python
# station/tests/test_wiring.py
from station.flow import STEPS, run_flow
from station.wiring import build_handlers

class Spy:
    def __init__(self):
        self.calls = []
    def __call__(self, name):
        return lambda: self.calls.append(name)

def test_handlers_cover_all_steps():
    # поддельный контекст: каждый шаг подменён шпионом
    spy = Spy()
    handlers = {s: spy(s) for s in STEPS}
    # build_handlers должен вернуть по обработчику на каждый шаг
    real = build_handlers(_FakeCtx())
    assert set(real) == set(STEPS)

class _FakeCtx:
    class model:  # noqa
        key = "cudy_wbr3000uax-v1"
    device_dir = None
```

- [ ] **Step 2: Запустить, убедиться что падает**

Run: `python -m pytest station/tests/test_wiring.py -v`
Expected: FAIL (нет полноценного `build_handlers`)

- [ ] **Step 3: Дописать `wiring.py`**

Реализовать `make_context` и `build_handlers`, где каждый шаг — замыкание над `ctx`, вызывающее соответствующий модуль (`artifacts.ensure_artifacts`, `network.check_ready`, `stock_ui.identify`, `mtd.backup_all`, `mtd.write_and_verify` дважды, `tftp.ReadOnlyTftp`, `commands.*`, `passport.save_passport`). Шаг `write_bootloader` вызывает `insmod_mtd_rw`, затем `write_and_verify` для FIP и BL2.

- [ ] **Step 4: Запустить весь набор**

Run: `python -m pytest station/ -v`
Expected: PASS (все задачи вместе)

- [ ] **Step 5: Добавить джобу в CI**

В `.github/workflows/ci.yml` добавить джобу `station`:

```yaml
  station:
    runs-on: ubuntu-latest
    timeout-minutes: 8
    steps:
      - uses: actions/checkout@v6
      - uses: actions/setup-python@v5
        with:
          python-version: "3.11"
      - run: pip install pytest paramiko
      - run: python -m pytest station/ -v
```

- [ ] **Step 6: Коммит**

```bash
git add station/wiring.py station/tests/test_wiring.py .github/workflows/ci.yml
git commit -m "feat(station): проводка шагов и джоба CI для станции"
```

---

## Самопроверка

- **Покрытие описания.** Все десять шагов из раздела «Порядок работы» описания разложены по задачам: подготовка файлов (T2), сеть (T8), вход и опознание (T12), доступ (T12), копии (T5), запись загрузчика (T6), TFTP (T7), установка (T13), приёмка (T13), паспорт (T9). Граница `Remote` — T4. Возобновление — T10. Сторонние файлы — T3. Гейт непроверенной модели — T14.
- **Проверки без железа** из раздела «Проверка» описания: `artifacts` (T2), `mtd` двойное чтение и обратное чтение (T5, T6), `tftp` (T7), `flow` порядок и возобновление (T10), `network` (T8) — все на месте.
- **На железе** — вне плана, помечено в описании как ручная приёмка; в коде за это отвечает флаг `--allow-untested` и пустой `known_stock_versions`.
- **Типы.** `Remote` (T4) используется одинаково в T5, T6, T11. `Partition` — T4, далее без переименований. `ensure_artifacts`, `load_thirdparty`, `write_and_verify`, `run_flow`, `save_passport` — сигнатуры совпадают между определением и вызовом в T15.
