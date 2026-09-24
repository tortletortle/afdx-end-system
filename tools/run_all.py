#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""一条命令跑完所有机器校验：改文档/改地址表/改寄存器之后必须全绿再提交。

    python3 tools/run_all.py            # 5 个校验器
    python3 tools/run_all.py --strict   # 额外运行 selfcheck_claims，失败时严格模式也失败

每个校验器只做机器可判的事：结构、算术、交叉引用、同源对账。它们全绿不代表 RTL 正确，
只代表「文档不自相矛盾、数字可复算」。RTL 的正确性归 §12 的用例。
"""
import os, subprocess, sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)

# 平铺命名（tools_*.py / doc_regs.yaml）是通过文件隧道同步过来的备份布局，
# 里面的脚本按 tools/ + doc/ 目录找文件与文档，直接跑会 SKIP 全部步骤、给出假绿假红。
if os.path.basename(HERE) != "tools" and os.path.exists(os.path.join(HERE, "tools_run_all.py")):
    print("当前是平铺布局（tools_*.py / doc_regs.yaml），校验器要按 tools/ + doc/ 目录运行。")
    print("归位（在项目根目录执行）：")
    print("  New-Item -ItemType Directory -Force tools, doc | Out-Null")
    print("  Get-ChildItem tools_*.py | ForEach-Object { Move-Item $_.FullName (Join-Path 'tools' ($_.Name -replace '^tools_','')) -Force }")
    print("  Move-Item doc_regs.yaml doc\regs.yaml -Force")
    print("然后：python tools\run_all.py")
    sys.exit(2)
STEPS = [
    ("verify_all", "全文一致性（章节/交叉引用/表格/端口/口径）", "verify_all.py"),
    ("check_addr", "§7.14 地址表（重叠、容量声明、PMEM 对齐）", "check_addr.py"),
    ("check_s9", "§9 存储预算（逐行反算 Kbit 与块数）", "check_s9_final.py"),
    ("gen_regs", "寄存器同源（YAML ↔ 附录 A ↔ A.1~A.3）", "gen_regs.py"),
    ("check_doc_numbers", "§8.2 用例数字（判决式复算）", "check_doc_numbers.py"),
]


def main():
    bad = []
    for name, what, script in STEPS:
        p = os.path.join(HERE, script)
        if not os.path.exists(p):
            print("SKIP  %-18s 缺 %s" % (name, script)); bad.append(name + "(缺文件)"); continue
        r = subprocess.run([sys.executable, p], cwd=ROOT, capture_output=True, text=True)
        tail = [l for l in (r.stdout or "").splitlines() if l.strip()]
        err = [l for l in (r.stderr or "").splitlines() if l.strip()]
        last = (tail[-1] if tail else (err[-1] if err else "(无输出)")).strip()
        print("%-4s %-18s %s" % ("PASS" if r.returncode == 0 else "FAIL", name, last[:104]))
        if r.returncode:
            bad.append(name)
            for l in tail:
                if "✗" in l or "FAIL" in l or "不一致" in l or "错误" in l:
                    print("       " + l.strip()[:150])
    if "--strict" in sys.argv:
        print()
        sys.stdout.flush()  # 父进程被捕获输出时，确保五项 PASS 先于子进程的自查内容显示
        script = os.path.join(HERE, "selfcheck_claims.py")
        if not os.path.exists(script):
            print("FAIL selfcheck_claims 缺自查脚本")
            bad.append("selfcheck_claims(缺文件)")
        else:
            r = subprocess.run([sys.executable, script], cwd=ROOT)
            if r.returncode:
                print("FAIL selfcheck_claims 口径/数字自查未通过")
                bad.append("selfcheck_claims")
            else:
                print("PASS selfcheck_claims 模型与文档一致（不代表 RTL 合规）")
    print("\n== 结论 ==")
    if bad:
        print("未通过：%s —— 先改文档，别改校验器来迁就它" % "、".join(bad)); return 1
    print("5/5 全绿%s：文档自洽、数字可复算。RTL 与仿真仍需在 eLinx/ModelSim 里跑 §12 的用例。" %
          ("，自查通过" if "--strict" in sys.argv else ""))
    return 0


if __name__ == "__main__":
    sys.exit(main())

