import re, sys
sys.path.insert(0, "")
import hpack.huffman_constants as c

src = open("src/flyology-http-http_2_huffman.adb").read()

def grab(name):
    m = re.search(name + r"\s*:\s*constant\s+\w+\s*:=\s*\((.*?)\);", src, re.S)
    body = m.group(1)
    body = re.sub(r"--[^\n]*", "", body)
    toks = re.findall(r"16#([0-9A-Fa-f_]+)#|(?<![\w#])(\d[\d_]*)(?![\w#])", body)
    out = []
    for h, d in toks:
        out.append(int(h.replace("_", ""), 16) if h else int(d.replace("_", "")))
    return out

codes = grab("Codes")
lengths = grab("Lengths")
print("ada codes:", len(codes), " ada lengths:", len(lengths))
print("rfc codes:", len(c.REQUEST_CODES), " rfc lengths:", len(c.REQUEST_CODES_LENGTH))

bad = 0
if len(codes) != 257 or len(lengths) != 257:
    print("LENGTH MISMATCH - parse or table size problem")
else:
    for i in range(257):
        if codes[i] != c.REQUEST_CODES[i] or lengths[i] != c.REQUEST_CODES_LENGTH[i]:
            bad += 1
            print("symbol %3d: ada code=%#x len=%d   rfc code=%#x len=%d"
                  % (i, codes[i], lengths[i], c.REQUEST_CODES[i],
                     c.REQUEST_CODES_LENGTH[i]))
    print("mismatches:", bad)
    if bad == 0:
        print("Huffman table matches RFC 7541 Appendix B (all 257 symbols).")
