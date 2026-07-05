#!/usr/bin/env python3
"""Generate bluefield-ocp.generated.Containerfile from fragments under containerfile/.

The Containerfile is assembled by concatenating fragments sorted by their
numeric filename prefix:

  containerfile/base/                 always included
  containerfile/driver-source/<name>/ exactly one, selected with --driver-source
  containerfile/rhel-source/<name>/   exactly one, selected with --rhel-source
  containerfile/optionals/<name>/     zero or more, selected with --enable

A fragment may start with metadata lines of the form "#% key: value" which are
stripped from the output. Supported keys:

  desc:      one-line description, shown by --list
  requires:  space-separated feature tokens that must be enabled
  conflicts: space-separated feature tokens that must NOT be enabled

Feature tokens are optional names (e.g. "debug-tools") or a selected variant
in the form "driver-source=<name>" / "rhel-source=<name>".

Additional fragment roots with the same layout (base/, driver-source/,
optionals/) can be overlaid with --extra-dir, e.g. a private directory in a
parent project that embeds this repository as a submodule. Overlay fragments
are merged on top of the public ones: new variant directories add driver
sources/optionals, a file with the same relative path overrides the public
one, and an override whose body is empty (metadata only) removes that step.

Fragment bodies are rendered through Jinja2. All variables passed via
--argfile or --set are available as template variables (e.g. {{ OCP_VERSION }}).
The selection context (driver_source, rhel_source, optionals, enabled) is
also available.

Requires: jinja2  (pip install jinja2)
"""

import argparse
import re
import sys
from pathlib import Path

import jinja2

ROOT = Path(__file__).resolve().parents[1]
FRAG_ROOT = ROOT / "containerfile"
# Written to the current working directory, not the repository root.
DEFAULT_OUTPUT = Path("bluefield-ocp.generated.Containerfile")
META_PREFIX = "#%"


def parse_fragment(path):
    """Split a fragment into (metadata dict, body text)."""
    meta = {}
    body_lines = []
    in_header = True
    for line in path.read_text().splitlines():
        if in_header and line.startswith(META_PREFIX):
            key, _, value = line[len(META_PREFIX):].partition(":")
            meta[key.strip()] = value.strip()
        else:
            in_header = False
            body_lines.append(line)
    return meta, "\n".join(body_lines).strip("\n")


def parse_argfile(path):
    """Read KEY=VALUE pairs from a file, skipping comments and blanks."""
    values = {}
    for line in path.read_text().splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        key, _, value = line.partition("=")
        if _:
            values[key.strip()] = value.strip()
    return values


def make_env(roots):
    """Create a Jinja2 environment backed by the fragment roots."""
    return jinja2.Environment(
        loader=jinja2.FileSystemLoader([str(r) for r in roots]),
        keep_trailing_newline=True,
        trim_blocks=True,
        lstrip_blocks=True,
        undefined=jinja2.StrictUndefined,
    )


def merge_fragments(roots, subpath):
    """Merge <root>/<subpath>/*.j2 fragments across roots; same filename in a
    later root overrides the earlier one. Returns {filename: path}."""
    files = {}
    for root in roots:
        d = root / subpath
        if d.is_dir():
            for p in sorted(d.glob("*.j2")):
                files[p.name] = p
    return files


def discover(subdir, roots):
    """Map variant name -> sorted fragment paths, merged across all roots."""
    variants = {}
    for root in roots:
        base = root / subdir
        if base.is_dir():
            for d in sorted(base.iterdir()):
                if d.is_dir() and any(d.glob("*.j2")):
                    variants.setdefault(d.name, None)
    return {name: [path for _, path in
                   sorted(merge_fragments(roots, Path(subdir) / name).items())]
            for name in variants}


def variant_desc(frags):
    for frag in frags:
        desc = parse_fragment(frag)[0].get("desc")
        if desc:
            return desc
    return "(no description)"


def check_constraints(frag, meta, enabled):
    problems = []
    for token in meta.get("requires", "").split():
        if token not in enabled:
            problems.append(f"{frag}: requires '{token}'")
    for token in meta.get("conflicts", "").split():
        if token in enabled:
            problems.append(f"{frag}: conflicts with '{token}'")
    return problems


def build(driver_source, rhel_source, optionals,
          driver_sources, rhel_sources, all_optionals, roots, template_vars):
    env = make_env(roots)

    context = dict(template_vars)
    context["driver_source"] = driver_source
    context["rhel_source"] = rhel_source
    context["optionals"] = optionals

    frags = sorted(
        list(merge_fragments(roots, "base").items())
        + [(p.name, p) for p in driver_sources[driver_source]]
        + [(p.name, p) for p in rhel_sources[rhel_source]]
        + [(p.name, p) for name in optionals for p in all_optionals[name]]
    )

    enabled = {f"driver-source={driver_source}",
               f"rhel-source={rhel_source}", *optionals}
    context["enabled"] = enabled

    bodies, problems = [], []
    for _, path in frags:
        meta, body = parse_fragment(path)
        problems += check_constraints(path, meta, enabled)
        if body:  # an empty-bodied override removes the step
            rendered = env.from_string(body).render(context)
            if rendered.strip():
                bodies.append(rendered)
    if problems:
        sys.exit("error: invalid combination:\n  " + "\n  ".join(problems))

    cmd = f"./scripts/generate.py --driver-source {driver_source} --rhel-source {rhel_source}"
    for name in optionals:
        cmd += f" --enable {name}"
    for root in roots[1:]:
        cmd += f" --extra-dir {root}"
    for k, v in template_vars.items():
        cmd += f" --set {k}={v}"
    banner = (
        "# GENERATED FILE - DO NOT EDIT.\n"
        f"# Generated from containerfile/ fragments by: {cmd}\n"
    )
    output = banner + "\n" + "\n\n".join(bodies) + "\n"
    return re.sub(r'\n{3,}', '\n\n', output)


def main():
    # --extra-dir must be parsed before discovery, since the available driver
    # sources and optionals (argparse choices) depend on the overlaid roots.
    pre = argparse.ArgumentParser(add_help=False)
    pre.add_argument("-x", "--extra-dir", action="append", default=[],
                     metavar="DIR", type=Path,
                     help="additional fragment root overlaid on containerfile/ "
                          "(same layout; same-named files override, empty body "
                          "removes a step; repeatable)")
    pre_args, _ = pre.parse_known_args()
    roots = [FRAG_ROOT]
    for extra in pre_args.extra_dir:
        if not extra.is_dir():
            sys.exit(f"error: --extra-dir {extra}: not a directory")
        roots.append(extra.resolve())

    driver_sources = discover("driver-source", roots)
    rhel_sources = discover("rhel-source", roots)
    all_optionals = discover("optionals", roots)

    parser = argparse.ArgumentParser(
        parents=[pre],
        description="Generate bluefield-ocp.generated.Containerfile from fragments under containerfile/.")
    parser.add_argument("-d", "--driver-source", default="prebuilt",
                        metavar="NAME", choices=sorted(driver_sources),
                        help="driver installation source (default: %(default)s)")
    parser.add_argument("-r", "--rhel-source", default="rhsm",
                        metavar="NAME", choices=sorted(rhel_sources),
                        help="RHEL package source (default: %(default)s)")
    parser.add_argument("-e", "--enable", action="append", default=[],
                        metavar="OPTIONAL", choices=sorted(all_optionals),
                        help="enable an optional feature (repeatable)")
    parser.add_argument("-o", "--output", type=Path, default=DEFAULT_OUTPUT,
                        help="output path, '-' for stdout (default: %(default)s)")
    parser.add_argument("-l", "--list", action="store_true",
                        help="list driver sources and optionals, then exit")
    parser.add_argument("--check", action="store_true",
                        help="verify the output file is up to date, do not write")
    parser.add_argument("-a", "--argfile", action="append", default=[],
                        metavar="FILE", type=Path,
                        help="read KEY=VALUE template variables from a file "
                             "(repeatable; later files override earlier ones)")
    parser.add_argument("-s", "--set", action="append", default=[],
                        metavar="KEY=VALUE",
                        help="set a template variable (repeatable; overrides argfile)")
    args = parser.parse_args()

    if args.list:
        print("driver sources (--driver-source):")
        for name, frags in driver_sources.items():
            print(f"  {name:<14} {variant_desc(frags)}")
        print("rhel sources (--rhel-source):")
        for name, frags in rhel_sources.items():
            print(f"  {name:<14} {variant_desc(frags)}")
        print("optionals (--enable):")
        if not all_optionals:
            print("  (none)")
        for name, frags in all_optionals.items():
            print(f"  {name:<14} {variant_desc(frags)}")
        return

    # Collect template variables: argfiles first, then --set overrides.
    template_vars = {}
    for af in args.argfile:
        if not af.is_file():
            sys.exit(f"error: --argfile {af}: file not found")
        template_vars.update(parse_argfile(af))
    for kv in args.set:
        key, sep, value = kv.partition("=")
        if not sep:
            sys.exit(f"error: --set requires KEY=VALUE format, got: {kv}")
        template_vars[key] = value

    optionals = list(dict.fromkeys(args.enable))  # dedupe, keep order
    content = build(args.driver_source, args.rhel_source, optionals,
                    driver_sources, rhel_sources, all_optionals, roots,
                    template_vars)

    if args.check:
        current = args.output.read_text() if args.output.is_file() else None
        if current != content:
            sys.exit(f"error: {args.output} is out of date, regenerate it")
        print(f"{args.output} is up to date")
    elif str(args.output) == "-":
        sys.stdout.write(content)
    else:
        args.output.write_text(content)
        print(f"wrote {args.output}")


if __name__ == "__main__":
    main()
