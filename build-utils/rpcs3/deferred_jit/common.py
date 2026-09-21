"""Shared source-rewrite primitives for NeoStation's passive RPCS3 loader."""
from __future__ import annotations
from dataclasses import dataclass

MARKER = "NEOSTATION_RPCS3_DEFERRED_JIT_V1"


class PatchError(RuntimeError):
    pass


def replace_once(text: str, old: str, new: str, label: str) -> str:
    count = text.count(old)
    if count != 1:
        raise PatchError(f"{label}: expected one anchor, found {count}")
    return text.replace(old, new, 1)


@dataclass(frozen=True)
class Initializer:
    start: int
    end: int
    statement: str
    expression: str


def _initializer_at(text: str, anchor: str, start: int = 0) -> Initializer:
    """Return one complete C++ initializer statement beginning at *anchor*.

    The scanner understands comments, strings, character literals and nested
    (), [] and {} delimiters. The first top-level semicolon terminates the
    initializer, including immediately-invoked lambdas.
    """
    begin = text.find(anchor, start)
    if begin < 0:
        raise PatchError(f"initializer anchor not found: {anchor!r}")
    anchor_equals = anchor.rfind("=")
    equals = begin + anchor_equals if anchor_equals >= 0 else text.find("=", begin + len(anchor))
    if equals < 0:
        raise PatchError(f"initializer has no '=': {anchor!r}")

    paren = bracket = brace = 0
    quote: str | None = None
    escape = False
    line_comment = False
    block_comment = False
    index = equals + 1
    while index < len(text):
        char = text[index]
        nxt = text[index + 1] if index + 1 < len(text) else ""

        if line_comment:
            if char == "\n":
                line_comment = False
            index += 1
            continue
        if block_comment:
            if char == "*" and nxt == "/":
                block_comment = False
                index += 2
            else:
                index += 1
            continue
        if quote is not None:
            if escape:
                escape = False
            elif char == "\\":
                escape = True
            elif char == quote:
                quote = None
            index += 1
            continue
        if char == "/" and nxt == "/":
            line_comment = True
            index += 2
            continue
        if char == "/" and nxt == "*":
            block_comment = True
            index += 2
            continue
        if char in ('"', "'"):
            quote = char
            index += 1
            continue
        if char == "(":
            paren += 1
        elif char == ")":
            paren -= 1
        elif char == "[":
            bracket += 1
        elif char == "]":
            bracket -= 1
        elif char == "{":
            brace += 1
        elif char == "}":
            brace -= 1
        elif char == ";" and paren == bracket == brace == 0:
            statement = text[begin:index + 1]
            expression = text[equals + 1:index].strip()
            return Initializer(begin, index + 1, statement, expression)
        if min(paren, bracket, brace) < 0:
            raise PatchError(f"unbalanced initializer near {anchor!r}")
        index += 1
    raise PatchError(f"unterminated initializer near {anchor!r}")


def _all_initializers(text: str, anchor: str) -> list[Initializer]:
    result: list[Initializer] = []
    position = 0
    while True:
        found = text.find(anchor, position)
        if found < 0:
            return result
        item = _initializer_at(text, anchor, found)
        result.append(item)
        position = item.end


def _wrap_initializer(
    text: str,
    item: Initializer,
    ios_declaration: str,
    builder_name: str,
    return_type: str,
) -> str:
    replacement = f"""#ifdef RPCS3_IOS
// {MARKER}: constant-initialized null pointer; no JIT work is legal in dyld.
{ios_declaration}
static auto {builder_name}() -> {return_type}
{{
\treturn {item.expression};
}}
#else
{item.statement}
#endif"""
    return text[:item.start] + replacement + text[item.end:]
