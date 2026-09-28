"""check_blend_bytes.py -- alg_blend_bytes.v(整字并行版)对拍

和 check_blend.py 用同一份金标准(blend_golden.txt, 由 gen_blend_golden.py 现算),
所以这个脚本回答的是: 把 16 个字节并成一条 128bit 字一次算完, 结果是否与
逐字节版(以及 Python 的 temporal_blend)一致。判定门槛与 check_blend.py 完全相同。

运行(仓库根目录):
    python sim\\algo\\model\\check_blend_bytes.py
需要 iverilog/vvp: 设 ALG_OSS_BIN 指向 oss-cad-suite\\bin, 或者直接放进 PATH。
"""

import os
import re
import subprocess
import sys

import check_blend as cb           # 复用 oss_env/exe/gen_golden/路径

TB_NAME = "tb_alg_blend_bytes.v"
RTL = os.path.join(cb.REPO, "rtl", "algo", "alg_blend_bytes.v")


def build():
    os.makedirs(cb.RUN, exist_ok=True)
    vvp = os.path.join(cb.RUN, "blend_bytes.vvp")
    src = [os.path.join(cb.TB, TB_NAME), RTL]
    p = subprocess.run([cb.exe("iverilog"), "-g2012", "-o", vvp] + src,
                       cwd=cb.RUN, capture_output=True, text=True,
                       encoding="utf-8", errors="replace", env=cb.oss_env())
    if p.returncode != 0:
        print(p.stdout)
        print(p.stderr)
        raise SystemExit("iverilog failed")
    return vvp


def run(vvp):
    p = subprocess.run([cb.exe("vvp"), os.path.basename(vvp),
                        "+GOLDEN=../" + os.path.basename(cb.GOLDEN)],
                       cwd=os.path.dirname(vvp), capture_output=True, text=True,
                       encoding="utf-8", errors="replace", env=cb.oss_env())
    return p.stdout + p.stderr


def main(argv):
    cb.gen_golden(force="--regen" in argv)
    out = run(build())

    per_temp = {}
    for m in re.finditer(r"^TEMP (\d+) rows (\d+) mism (\d+) maxd (\d+) alpha_q8 (\d+)$",
                         out, re.M):
        per_temp[int(m.group(1))] = (int(m.group(2)), int(m.group(3)),
                                     int(m.group(4)), int(m.group(5)))
    summary = re.search(r"^BLEND_SUMMARY total=(\d+) mism=(\d+) maxd=(\d+) "
                        r"alut_mism=(\d+) xcount=(\d+)$", out, re.M)
    if not summary:
        print(out)
        raise SystemExit("no BLEND_SUMMARY in simulation output (tb did not finish?)")

    total, mism, maxd, alut, xcount = (int(summary.group(i)) for i in range(1, 6))

    for ln in out.splitlines():
        if ln.startswith(("ROWW", "DIFF", "ALUT", "FATAL")):
            print(ln)
    print()
    print("golden rows        : %d" % total)
    print("alpha LUT mismatch : %d   (必须 0)" % alut)
    print("max |RTL - python| : %d LSB" % maxd)
    print("X (未定态) 采样数  : %d   (必须 0)" % xcount)
    print("total mismatches   : %d / %d  (%.1f%%)"
          % (mism, total, 100.0 * mism / max(total, 1)))
    print()
    print("TEMP   rows    mism   maxd  alpha_q8   要求的")
    for t in sorted(per_temp):
        rows, tm, td, a8 = per_temp[t]
        need = "必须 0" if t in cb.EXACT else "允许 <=1"
        print("%4d %6d %7d %6d %8d   %s" % (t, rows, tm, td, a8, need))
    print()

    bad = []
    for t in cb.EXACT:
        if t not in per_temp:
            bad.append("TEMP %d 没有出现在仿真输出里" % t)
        elif per_temp[t][1] != 0:
            bad.append("TEMP %d 有 %d 个像素不逐位相同(必须为 0)" % (t, per_temp[t][1]))
    if alut != 0:
        bad.append("alpha LUT 与 Python 不一致 %d 次" % alut)
    if maxd > 1:
        bad.append("最大差 %d LSB > 1" % maxd)
    if xcount != 0:
        bad.append("有 %d 个采样是 X(未定态), 判定不可信" % xcount)
    if bad:
        print()
        for b in bad:
            print("FAIL: " + b)
        return 1
    print("RESULT: alg_blend_bytes.v 与逐字节版同源同判据, <=1 LSB; "
          "TEMP %s 逐位相同(RTL 与该档 Python 金标准逐位相同)"
          % ",".join(str(t) for t in cb.EXACT))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
