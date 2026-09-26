import numpy as np
K = np.array([[32,38,40,38,32],[38,45,47,45,38],[40,47,50,47,40],[38,45,47,45,38],[32,38,40,38,32]])
win_hex = {}
rows = []
for ln in open("dbg_gauss.txt", encoding="ascii", errors="replace"):
    t = ln.split()
    if len(t) != 11: continue
    x, y = int(t[0]), int(t[1])   # 注意: 这里 t[0]=x t[1]=y (frame 在 t[0]?) 
    rows.append(t)
print("tokens per line:", len(rows[0]), rows[0][:4])
def parse(t):
    x,y = int(t[1]), int(t[2])
    w = int(t[3],16)
    pix = [(w >> (8*i)) & 0xFF for i in range(25)]
    r = [int(v,16) for v in t[5:10]]
    tot = int(t[10],16)
    out = int(t[4],16)
    return x,y,pix,r,tot,out
for x,y,pix,r,tot,out in [parse(t) for t in rows]:
    M = np.array(pix).reshape(5,5)
    rows_sum = [int((M[i]*K[i]).sum()) for i in range(5)]
    tot2 = int((M*K).sum())
    exp = (tot2>>10) + ((tot2>>9)&1)
    if y in (0,1,2,3) and x in (0,1,15,16):
        print(f"({x},{y}) rtl_rows={r} py_rows={rows_sum} rtl_tot={tot} py_tot={tot2} rtl_out={out} py_out={exp}")

