#!/usr/bin/env python3
"""Small dependency-free syntax/reference validator for an ASCII Xcode project file."""
from __future__ import annotations
import re
import sys
from pathlib import Path

TOKEN = re.compile(
    r'''\s+|//[^\n]*|/\*.*?\*/|"(?:\\.|[^"\\])*"|\$\([^)]*\)|[{}()=;,]|[^\s{}()=;,]+''',
    re.S,
)

class ParseError(RuntimeError):
    pass

def tokenize(text: str) -> list[str]:
    output: list[str] = []
    position = 0
    for match in TOKEN.finditer(text):
        if match.start() != position:
            raise ParseError(f"Unexpected text at byte {position}")
        position = match.end()
        token = match.group(0)
        if token.isspace() or token.startswith("//") or token.startswith("/*"):
            continue
        output.append(token)
    if position != len(text):
        raise ParseError(f"Unexpected trailing text at byte {position}")
    return output

class Parser:
    def __init__(self, tokens: list[str]):
        self.tokens = tokens
        self.index = 0

    def peek(self) -> str | None:
        return self.tokens[self.index] if self.index < len(self.tokens) else None

    def take(self, expected: str | None = None) -> str:
        token = self.peek()
        if token is None:
            raise ParseError("Unexpected end of file")
        if expected is not None and token != expected:
            raise ParseError(f"Expected {expected!r}, found {token!r} at token {self.index}")
        self.index += 1
        return token

    def scalar(self) -> str:
        token = self.take()
        if token.startswith('"'):
            return bytes(token[1:-1], "utf-8").decode("unicode_escape")
        return token

    def value(self):
        token = self.peek()
        if token == "{":
            return self.dictionary()
        if token == "(":
            return self.array()
        return self.scalar()

    def dictionary(self) -> dict[str, object]:
        result: dict[str, object] = {}
        self.take("{")
        while self.peek() != "}":
            key = self.scalar()
            self.take("=")
            result[key] = self.value()
            self.take(";")
        self.take("}")
        return result

    def array(self) -> list[object]:
        result: list[object] = []
        self.take("(")
        while self.peek() != ")":
            result.append(self.value())
            if self.peek() == ",":
                self.take(",")
            elif self.peek() != ")":
                raise ParseError(f"Expected ',' or ')', found {self.peek()!r}")
        self.take(")")
        return result


def main() -> int:
    path = Path(sys.argv[1] if len(sys.argv) > 1 else "PCRTDiagnosticsMac.xcodeproj/project.pbxproj")
    root = Parser(tokenize(path.read_text(encoding="utf-8"))).value()
    if not isinstance(root, dict):
        raise ParseError("Project root is not a dictionary")
    objects = root.get("objects")
    root_id = root.get("rootObject")
    if not isinstance(objects, dict) or not isinstance(root_id, str) or root_id not in objects:
        raise ParseError("objects/rootObject is missing or invalid")

    object_ids = set(objects)
    reference_keys = {
        "fileRef", "productRef", "containerPortal", "target", "targetProxy",
        "buildConfigurationList", "productReference", "mainGroup", "productRefGroup",
        "package", "baseConfigurationReference",
    }
    missing: list[str] = []
    for owner, value in objects.items():
        if not isinstance(value, dict):
            continue
        for key, ref in value.items():
            if key in reference_keys and isinstance(ref, str) and re.fullmatch(r"[A-F0-9]{24}", ref) and ref not in object_ids:
                missing.append(f"{owner}.{key} -> {ref}")
            if key in {"buildPhases", "dependencies", "packageProductDependencies", "targets", "buildConfigurations", "packageReferences", "children", "files"} and isinstance(ref, list):
                for item in ref:
                    if isinstance(item, str) and re.fullmatch(r"[A-F0-9]{24}", item) and item not in object_ids:
                        missing.append(f"{owner}.{key} -> {item}")
    if missing:
        raise ParseError("Missing object references:\n" + "\n".join(missing))

    print(f"Validated {path}: {len(objects)} project objects, root {root_id}")
    return 0

if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, ParseError) as error:
        print(f"PBX validation failed: {error}", file=sys.stderr)
        raise SystemExit(1)
