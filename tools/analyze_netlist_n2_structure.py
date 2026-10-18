"""Audit every cell output in the two NETLIST-N2 affected modules.

Resolves actual bit selections, concatenations, module ports and module aliases.
Produces evidence only; never changes either IL snapshot.
"""
from __future__ import annotations

import argparse
import collections
import json
from pathlib import Path
import re

from run_netlist_n2_reload import audit_cout, now, sha, write_json

ROOT = Path(__file__).resolve().parents[1]
SELECTED = {
    r"$paramod$3eec85f513867eb67bf2c18df61a999b8a6e24d5\a615a_tftp",
    r"$paramod$4c222b690d4305e2e1151b8d76ce6d509e42661b\rx_reassembly",
}


def output_ports(cell_type, port_definitions):
    if cell_type in port_definitions:
        return port_definitions[cell_type], "module wire port declarations"
    if cell_type in {"$_LCELL_COMB_", "$_LCELL_COMB_INVA_"}:
        return {"\\Y", "\\COUT"}, "installed stratix/cells_map.v module declaration"
    if cell_type == "$lut" or cell_type in {
        "$_AND_", "$_OR_", "$_XOR_", "$_NOT_", "$_MUX_", "$_NAND_", "$_NOR_", "$_XNOR_",
    }:
        return {"\\Y"}, "generic logic cell interface"
    if re.fullmatch(r"\$_DFF.*_|\$__DFF.*_", cell_type):
        return {"\\Q"}, "flip-flop cell interface"
    raise ValueError(f"Unclassified cell type: {cell_type}")


def header_pass(path):
    wire_info = collections.defaultdict(dict)
    ports = collections.defaultdict(set)
    module = None
    for line in path.open(encoding="utf-8"):
        if line.startswith("module "):
            module = line[7:].strip()
        elif line.startswith("end"):
            module = None
        elif module and line.startswith("  wire "):
            tokens = line.split()
            name = tokens[-1]
            width = int(tokens[tokens.index("width") + 1]) if "width" in tokens[:-1] else 1
            offset = int(tokens[tokens.index("offset") + 1]) if "offset" in tokens[:-1] else 0
            if module in SELECTED:
                wire_info[module][name] = (width, offset)
            if "output" in tokens[:-1]:
                ports[module].add(name)
    return wire_info, dict(ports)


def signal_bits(tokens, wires):
    """Expand a generated IL signal expression into bits, least significant first."""
    position = 0

    def one():
        nonlocal position
        token = tokens[position]
        position += 1
        if token == "{":
            parts = []
            while tokens[position] != "}":
                parts.append(one())
            position += 1
            return [bit for part in reversed(parts) for bit in part]
        if token.startswith(("$", "\\")):
            if position < len(tokens) and re.fullmatch(r"\[-?\d+(?::-?\d+)?\]", tokens[position]):
                select = tokens[position][1:-1]
                position += 1
                if ":" in select:
                    msb, lsb = map(int, select.split(":"))
                    step = 1 if msb >= lsb else -1
                    indices = range(lsb, msb + step, step)
                else:
                    indices = [int(select)]
            else:
                width, offset = wires.get(token, (1, 0))
                indices = range(offset, offset + width)
            return [(token, bit) for bit in indices]
        match = re.fullmatch(r"(\d+)'([01xz-]+)", token)
        if match:
            width, value = int(match[1]), match[2]
            if len(value) != width:
                raise ValueError(f"Unexpected nonexpanded constant {token}")
            return [("#constant", bit) for bit in reversed(value)]
        raise ValueError(f"Unknown signal token: {token}")

    result = one()
    if position != len(tokens):
        raise ValueError(f"Unexpected trailing signal tokens: {tokens[position:]}")
    return result


class AliasMap:
    def __init__(self):
        self.parent = {}

    def find(self, bit):
        path = []
        while bit in self.parent:
            path.append(bit)
            bit = self.parent[bit]
        for item in path:
            self.parent[item] = bit
        return bit

    def merge(self, a, b):
        a, b = self.find(a), self.find(b)
        if a == b:
            return
        if a[0] == "#constant":
            self.parent[b] = a
        else:
            self.parent[a] = b


def scan(path):
    wires, port_defs = header_pass(path)
    results = {}
    module = cell_type = cell_name = None
    module_data = None

    def finish_module():
        if module_data is None:
            return
        drivers = collections.defaultdict(list)
        for bit, entries in module_data["drivers"].items():
            canonical = module_data["aliases"].find(bit)
            if canonical[0] != "#constant":
                drivers[canonical].extend(entries)
        duplicate = {bit: rows for bit, rows in drivers.items() if len(rows) > 1}
        direct = {bit: rows for bit, rows in module_data["drivers"].items() if len(rows) > 1}
        results[module] = {
            "cell_count": sum(module_data["cell_types"].values()),
            "cell_types": dict(module_data["cell_types"]),
            "output_port_classification": module_data["classifications"],
            "all_cell_types_classified": True,
            "output_connection_counts_by_cell_type": dict(module_data["output_connections"]),
            "output_bit_count": sum(len(x) for x in module_data["drivers"].values()),
            "direct_duplicate_output_bits": len(direct),
            "alias_resolved_duplicate_output_bits": len(duplicate),
            "duplicate_examples": [{"bit": list(bit), "drivers": rows} for bit, rows in list(duplicate.items())[:8]],
            "undeclared_output_net_names": sorted(module_data["undeclared"]),
            "module_alias_bit_pairs": module_data["alias_pairs"],
            "limitation": "Structural driver enumeration only; does not prove function, cycles, timing or full-top acceptance.",
        }

    for lineno, line in enumerate(path.open(encoding="utf-8"), 1):
        if line.startswith("module "):
            module = line[7:].strip()
            module_data = None
            if module in SELECTED:
                module_data = {"drivers": collections.defaultdict(list), "aliases": AliasMap(),
                               "cell_types": collections.Counter(), "output_connections": collections.Counter(),
                               "classifications": {}, "undeclared": set(), "alias_pairs": 0}
            cell_type = cell_name = None
        elif line.startswith("end"):
            finish_module()
            module_data = None
            module = None
        elif module_data is None:
            continue
        elif line.startswith("  cell "):
            _, cell_type, cell_name = line.split(maxsplit=2)
            cell_name = cell_name.strip()
            module_data["cell_types"][cell_type] += 1
            outputs, basis = output_ports(cell_type, port_defs)
            module_data["classifications"][cell_type] = {"outputs": sorted(outputs), "basis": basis}
        elif line.startswith("  end"):
            cell_type = cell_name = None
        elif cell_type and line.lstrip().startswith("connect "):
            tokens = line.split()
            outputs, _ = output_ports(cell_type, port_defs)
            if tokens[1] in outputs:
                module_data["output_connections"][cell_type] += 1
                for index, bit in enumerate(signal_bits(tokens[2:], wires[module])):
                    if bit[0] == "#constant":
                        continue
                    if bit[0] not in wires[module]:
                        module_data["undeclared"].add(bit[0])
                    module_data["drivers"][bit].append({"cell": cell_name, "type": cell_type,
                                                       "port": tokens[1], "output_bit": index, "line": lineno})
        elif line.startswith("  connect "):
            tokens = line.split()[1:]
            # Split the two sigspecs by parsing successive prefixes.
            for split in range(1, len(tokens)):
                try:
                    lhs = signal_bits(tokens[:split], wires[module])
                    rhs = signal_bits(tokens[split:], wires[module])
                except (ValueError, IndexError):
                    continue
                if len(lhs) != len(rhs):
                    continue
                for a, b in zip(lhs, rhs):
                    module_data["aliases"].merge(a, b)
                module_data["alias_pairs"] += len(lhs)
                break
            else:
                raise ValueError(f"Could not parse module connect at line {lineno}")
    return {"path": str(path), "sha256": sha(path), "bytes": path.stat().st_size, "modules": results}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--out", type=Path, required=True)
    args = parser.parse_args()
    if args.out.exists():
        raise FileExistsError(args.out)
    source = ROOT / "out/netlist_n2_instrumented_20261014_r1"
    result = {"schema": "netlist-n2-structure-audit-v2", "created_local": now(),
              "parser_sha256": sha(Path(__file__)),
              "preabc": scan(source / "AFDX_top_preabc.il"),
              "postabc": scan(source / "AFDX_top_postabc.il")}
    for stage in ("preabc", "postabc"):
        cout = audit_cout(source / f"AFDX_top_{stage}.il")
        result[stage]["missing_cout_by_module"] = cout
        result[stage]["missing_cout_count"] = sum(len(x) for x in cout.values())
    write_json(args.out, result)
    print(json.dumps({stage: {"missing_cout_count": result[stage]["missing_cout_count"],
                            "modules": {module: {key: value for key, value in row.items() if key in {
                                "cell_count", "all_cell_types_classified", "output_bit_count",
                                "direct_duplicate_output_bits", "alias_resolved_duplicate_output_bits"}}
                                        for module, row in result[stage]["modules"].items()}}
                      for stage in ("preabc", "postabc")}, ensure_ascii=False))


if __name__ == "__main__":
    main()
