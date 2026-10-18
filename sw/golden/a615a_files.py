"""Bounded ARINC 615A control-file codecs for preparation and independent review.

This module handles files, not TFTP, ARINC 665 parts, or a complete 615A session.
The field layout is cross-referenced in doc/615A_控制文件与接入设计_20261009.md.
Progress is deliberately three opaque octets: public references disagree on
ASCII versus binary interpretation. No numeric conversion is implied here.
"""
from __future__ import annotations

from dataclasses import dataclass
from enum import IntEnum

MAX_FILE_BYTES = 8192
MAX_UPLOAD_FILES = 8  # Project capacity, not a claimed standard maximum.


class FormatError(ValueError):
    """A file does not satisfy the declared, bounded wire-format profile."""


class OperationStatus(IntEnum):
    ACCEPTED = 0x0001
    IN_PROGRESS = 0x0002
    COMPLETED = 0x0003
    IN_PROGRESS_WITH_DESCRIPTION = 0x0004
    DENIED = 0x1000
    NOT_SUPPORTED = 0x1002
    ABORTED_BY_TARGET = 0x1003
    ABORTED_BY_LOADER = 0x1004
    ABORTED_BY_OPERATOR = 0x1005
    HEADER_FILE_FAILED = 0x1007


def _uint(value: int, width: int) -> bytes:
    if type(value) not in (int, OperationStatus) or not 0 <= value < (1 << (8 * width)):
        raise FormatError(f"unsigned {width}-octet value out of range: {value!r}")
    return int(value).to_bytes(width, "big")


def _version(value: str) -> bytes:
    if not isinstance(value, str):
        raise FormatError("protocol version must be an explicit two-character string")
    try:
        raw = value.encode("ascii")
    except UnicodeEncodeError as exc:
        raise FormatError("protocol version must be ASCII") from exc
    if len(raw) != 2 or raw[0] != ord("A") or not ord("1") <= raw[1] <= ord("4"):
        raise FormatError("this reference profile accepts wire tags A1 through A4")
    return raw


def _text(value: str, *, optional: bool = False) -> bytes:
    if not isinstance(value, str):
        raise FormatError("text field must be a string")
    try:
        raw = value.encode("ascii")
    except UnicodeEncodeError as exc:
        raise FormatError("this project profile uses printable ASCII text") from exc
    if any(byte < 0x20 or byte > 0x7E for byte in raw):
        raise FormatError("text contains NUL or a non-printable ASCII octet")
    if not raw:
        if optional:
            return b"\x00"  # Canonical zero-length optional field.
        raise FormatError("required name is empty")
    if len(raw) > 254:
        raise FormatError("text exceeds the 255-octet field including its NUL")
    terminated = raw + b"\x00"
    return bytes([len(terminated)]) + terminated


def _envelope(version: str, payload: bytes) -> bytes:
    length = 6 + len(payload)
    if length > MAX_FILE_BYTES:
        raise FormatError("file exceeds the declared project buffer capacity")
    return _uint(length, 4) + _version(version) + payload


def _progress(value: bytes) -> bytes:
    if not isinstance(value, bytes) or len(value) != 3:
        raise FormatError("progress_raw must be exactly three explicit octets")
    return value


class _Reader:
    def __init__(self, raw: bytes, expected_version: str | None):
        if not isinstance(raw, bytes) or not 6 <= len(raw) <= MAX_FILE_BYTES:
            raise FormatError("file size is outside the declared buffer bounds")
        self.raw = raw
        self.offset = 0
        if self.uint(4) != len(raw):
            raise FormatError("declared file length differs from the complete file")
        try:
            self.version = self.take(2).decode("ascii")
        except UnicodeDecodeError as exc:
            raise FormatError("non-ASCII protocol version") from exc
        _version(self.version)
        if expected_version is not None and self.version != expected_version:
            raise FormatError("protocol version differs from the selected session")

    def take(self, length: int) -> bytes:
        if length < 0 or self.offset + length > len(self.raw):
            raise FormatError(f"truncated field at file offset {self.offset}")
        value = self.raw[self.offset:self.offset + length]
        self.offset += length
        return value

    def uint(self, width: int) -> int:
        return int.from_bytes(self.take(width), "big")

    def text(self, *, optional: bool = False) -> str:
        length = self.uint(1)
        if length == 0:
            if optional:
                return ""
            raise FormatError("required name has zero wire length")
        raw = self.take(length)
        if raw[-1] != 0 or b"\x00" in raw[:-1]:
            raise FormatError("text field must have exactly one terminal NUL")
        if not optional and len(raw) == 1:
            raise FormatError("required name is empty")
        if any(byte < 0x20 or byte > 0x7E for byte in raw[:-1]):
            raise FormatError("text is outside the project printable-ASCII profile")
        return raw[:-1].decode("ascii")

    def end(self) -> None:
        if self.offset != len(self.raw):
            raise FormatError("unconsumed trailing file octets")


@dataclass(frozen=True)
class Initialization:
    """The shared initialization layout used by LUI/LCI/LND/LNO."""

    version: str
    status: int
    description: str = ""

    def encode(self) -> bytes:
        return _envelope(self.version, _uint(self.status, 2) + _text(self.description, optional=True))

    @classmethod
    def decode(cls, raw: bytes, *, expected_version: str | None = None) -> Initialization:
        reader = _Reader(raw, expected_version)
        value = cls(reader.version, reader.uint(2), reader.text(optional=True))
        reader.end()
        return value


@dataclass(frozen=True)
class UploadEntry:
    filename: str
    part_number: str

    def encode(self) -> bytes:
        return _text(self.filename) + _text(self.part_number)


@dataclass(frozen=True)
class UploadRequest:
    version: str
    files: tuple[UploadEntry, ...]

    def encode(self) -> bytes:
        if not 1 <= len(self.files) <= MAX_UPLOAD_FILES:
            raise FormatError("LUR requires 1..8 entries in this project profile")
        body = _uint(len(self.files), 2) + b"".join(item.encode() for item in self.files)
        return _envelope(self.version, body)

    @classmethod
    def decode(cls, raw: bytes, *, expected_version: str | None = None) -> UploadRequest:
        reader = _Reader(raw, expected_version)
        count = reader.uint(2)
        if not 1 <= count <= MAX_UPLOAD_FILES:
            raise FormatError("LUR count is outside the declared 1..8 project capacity")
        files = tuple(UploadEntry(reader.text(), reader.text()) for _ in range(count))
        reader.end()
        return cls(reader.version, files)


@dataclass(frozen=True)
class UploadFileStatus:
    filename: str
    part_number: str
    progress_raw: bytes
    status: int
    description: str = ""

    def encode(self) -> bytes:
        return (_text(self.filename) + _text(self.part_number) + _progress(self.progress_raw)
                + _uint(self.status, 2) + _text(self.description, optional=True))


@dataclass(frozen=True)
class UploadStatus:
    """LUS layout only; progress octets carry no assumed numeric meaning."""

    version: str
    status: int
    counter: int
    estimated_time: int
    progress_raw: bytes
    files: tuple[UploadFileStatus, ...] = ()
    description: str = ""
    exception_timer: int | None = None

    def encode(self) -> bytes:
        if len(self.files) > MAX_UPLOAD_FILES:
            raise FormatError("LUS file count exceeds the project capacity")
        body = _uint(self.status, 2) + _text(self.description, optional=True) + _uint(self.counter, 2)
        if self.version == "A1":
            if self.exception_timer is not None:
                raise FormatError("the selected A1 layout has no exception-timer field")
        else:
            if self.exception_timer is None:
                raise FormatError("the selected layout requires an explicit exception timer")
            body += _uint(self.exception_timer, 2)
        body += _uint(self.estimated_time, 2) + _progress(self.progress_raw) + _uint(len(self.files), 2)
        body += b"".join(item.encode() for item in self.files)
        return _envelope(self.version, body)

    @classmethod
    def decode(cls, raw: bytes, *, expected_version: str | None = None) -> UploadStatus:
        reader = _Reader(raw, expected_version)
        status, description, counter = reader.uint(2), reader.text(optional=True), reader.uint(2)
        exception = None if reader.version == "A1" else reader.uint(2)
        estimated, progress, count = reader.uint(2), reader.take(3), reader.uint(2)
        if count > MAX_UPLOAD_FILES:
            raise FormatError("LUS file count exceeds the project capacity")
        files = tuple(UploadFileStatus(reader.text(), reader.text(), reader.take(3),
                                       reader.uint(2), reader.text(optional=True))
                      for _ in range(count))
        reader.end()
        return cls(reader.version, status, counter, estimated, progress, files, description, exception)
