"""Full audit of the bundled Python: import the top-level module of every installed
distribution under an isolated interpreter and confirm nothing is resolved from outside
the bundle. Run with `python -I runtime_check.py`; prints one JSON object."""
import importlib, importlib.metadata as md, json, os, sys, warnings

warnings.filterwarnings("ignore")
prefix = os.path.realpath(sys.prefix)
SKIP = ("_", "test", "tests", "pythonwin", "win32com", "win32comext", "win32", "isapi", "adodbapi")

outside_path = [p for p in sys.path if p and not os.path.realpath(p).startswith(prefix)]
failures, imported, dists = [], 0, 0
for d in md.distributions():
    dists += 1
    tops = (d.read_text("top_level.txt") or "").split()
    if not tops:
        tops = sorted({f.parts[0] for f in (d.files or [])
                       if f.suffix == ".py" and len(f.parts) > 1 and not f.parts[0].endswith(".dist-info")})
    for m in tops:
        if m.startswith(SKIP) or "-" in m:
            continue
        try:
            importlib.import_module(m)
            imported += 1
        except BaseException as e:      # noqa: BLE001  report everything
            failures.append({"distribution": d.metadata["Name"], "module": m,
                             "error": f"{type(e).__name__}: {str(e)[:120]}"})
this_script = os.path.realpath(__file__)
outside_modules = sorted({m.__file__ for m in list(sys.modules.values())
                          if getattr(m, "__file__", None) and os.path.isabs(m.__file__)
                          and os.path.realpath(m.__file__) != this_script
                          and not os.path.realpath(m.__file__).startswith(prefix)})
print(json.dumps({
    "python": sys.version.split()[0], "prefix": prefix, "distributions": dists,
    "imported": imported, "failures": failures, "outside_path": outside_path,
    "outside_modules": outside_modules,
    "ok": not failures and not outside_path and not outside_modules,
}))
