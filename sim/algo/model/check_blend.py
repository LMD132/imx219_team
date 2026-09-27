"""check_blend.py -- alg_blend.v 对拍(live_tune.py 的 TEMP 滑条 -> temporal_blend)

流程:
  1. gen_blend_golden.py 现算金标准 -> sim/algo/blend_golden.txt
     (金标准是 Python 自己算的, 不是 RTL 算的, 所以这不是自证)
  2. iverilog 编译 tb_alg_blend.v + rtl/algo/alg_blend.v, vvp 跑全部向量
  3. 判定:
       * o_alpha_q8 必须逐档等于 Python 的 round((100-TEMP)*256/100)  -> alut_mism == 0
       * |RTL - Python| <= 1 LSB (Q8 定点化的代价)
       * TEMP = 0/25/50/75 必须逐位完全相同

运行(仓库根目录):
    python sim\\algo\\model\\check_blend.py
需要 iverilog/vvp: 设 ALG_OSS_BIN 指向 oss-cad-suite\\bin, 或者直接放进 PATH。
"""

import os
import re
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
TB = os.path.abspath(os.path.join(HERE, ".."))          # sim/algo
REPO = os.path.abspath(os.path.join(TB, "..", ".."))    # 仓库根
RUN = os.path.join(TB, "run")
GOLDEN = os.path.join(TB, "blend_golden.txt")

OSS = os.environ.get("ALG_OSS_BIN", "")
EXACT = (0, 25, 50, 75)      # gen_blend_golden.py 的穷举结论: 这些档位逐位相同

_ENV = None


def exe(name):
    return os.path.join(OSS, name + ".exe") if OSS else name


def oss_env():
    global _ENV
    if _ENV is None:
        env = dict(os.environ)
        if OSS:
            bat = os.path.join(os.path.dirname(OSS.rstrip("\\")), "environment.bat")
            if os.path.exists(bat):
                p = subprocess.run(["cmd", "/c", "call %s >nul 2>&1 && set" % bat],
                                   capture_output=True, text=True,
                                   encoding="utf-8", errors="replace")
                for ln in p.stdout.splitlines():
                    if "=" in ln:
                        k, v = ln.split("=", 1)
                        env[k] = v
        _ENV = env
    return _ENV


def gen_golden(force=False):
    if force or not os.path.exists(GOLDEN):
        p = subprocess.run([sys.executable,
                            os.path.join(HERE, "gen_blend_golden.py"), GOLDEN],
                           capture_output=True, text=True,
                           encoding="utf-8", errors="replace")
        if p.returncode != 0:
            print(p.stdout)
            print(p.stderr)
            raise SystemExit("gen_blend_golden.py failed")
        print(p.stdout.strip().splitlines()[0])


def build():
    os.makedirs(RUN, exist_ok=True)
    vvp = os.path.join(RUN, "blend.vvp")
    src = [os.path.join(TB, "tb_alg_blend.v"),
           os.path.join(REPO, "rtl", "algo", "alg_blend.v")]
    p = subprocess.run([exe("iverilog"), "-g2012", "-o", vvp] + src,
                       cwd=RUN, capture_output=True, text=True,
                       encoding="utf-8", errors="replace", env=oss_env())
    if p.returncode != 0 or p.stderr.strip():
        print(p.stdout)
        print(p.stderr)
        if p.returncode != 0:
            raise SystemExit("iverilog failed")
    return vvp


def run(vvp):
    p = subprocess.run([exe("vvp"), os.path.basename(vvp),
                        "+GOLDEN=../" + os.path.basename(GOLDEN)],
                       cwd=os.path.dirname(vvp), capture_output=True, text=True,
                       encoding="utf-8", errors="replace", env=oss_env())
    return p.stdout + p.stderr


def main(argv):
    gen_golden(force="--regen" in argv)
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
        if ln.startswith("ROW") or ln.startswith("DIFF") or ln.startswith("ALUT"):
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
        need = "必须 0" if t in EXACT else "允许 <=1"
        print("%4d %6d %7d %6d %8d   %s" % (t, rows, tm, td, a8, need))
    print()

    bad = []
    for t in EXACT:
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

    worst = sorted(per_temp.items(), key=lambda kv: -kv[1][1])[:5]
    print("差 1 LSB 的档位里最靠前的几档: "
          + ", ".join("TEMP%d(%d/%d 像素)" % (k, v[1], v[0]) for k, v in worst))

    if bad:
        print()
        for b in bad:
            print("FAIL: " + b)
        return 1
    print()
    print("RESULT: alg_blend.v 与 live_tune.py + edge_pipeline.py:temporal_blend 一致 "
          "(<=1 LSB; TEMP %s 逐位相同)" % ",".join(str(t) for t in EXACT))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
