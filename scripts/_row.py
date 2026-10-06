import sys, json
d = json.load(sys.stdin)
temps = [x["temperature"] for x in d["sensors"] if x["kind"] != "Other"]
fans = d["fans"]
rpm = lambda i: str(round(fans[i]["rpm"])) if len(fans) > i and fans[i]["rpm"] is not None else ""
mode = str(int(fans[0]["mode"])) if fans and fans[0]["mode"] is not None else ""
print(f"{max(temps) if temps else ''},{rpm(0)},{rpm(1)},{mode}")
