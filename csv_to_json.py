#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
将「招聘信息源.csv」转换为 GPT Action 可消费的 campus-hiring.json。

用法:
    python csv_to_json.py [输入csv] [输出json]
默认输入: E:/数据源/招聘信息源.csv
默认输出: campus-hiring.json (当前目录)

字段映射（按 CSV 列顺序，0 起）:
    0  更新时间
    1  公司名称
    2  截止时间
    3  招聘类型（校招/秋招/实习…）
    4  目前人群（2027届…）
    5  公司类型（国企/私企/外企…）
    6  招聘岗位（"行业：xxx；岗位…"）
    7  城市
    8  公告链接
    9  投递链接
    10 投递状态
"""
import csv
import sys
import json
import hashlib
from datetime import datetime

INPUT_DEFAULT = "E:/数据源/招聘信息源.csv"
OUTPUT_DEFAULT = "campus-hiring.json"


def parse_date(s: str) -> str:
    s = (s or "").strip()
    if not s:
        return ""
    for fmt in ("%m/%d/%Y", "%Y-%m-%d", "%Y/%m/%d"):
        try:
            return datetime.strptime(s, fmt).strftime("%Y-%m-%d")
        except ValueError:
            continue
    return s  # 无法解析则原样保留（如「招满为止」）


def parse_role(cell: str):
    """把「行业：消费；货品管理岗,服装设计岗」拆成 (industry, positions)。"""
    cell = (cell or "").strip()
    if cell.startswith("行业：") or cell.startswith("行业:"):
        body = cell[3:]
        for sep in ("；", ";"):
            if sep in body:
                industry, positions = body.split(sep, 1)
                return industry.strip(), positions.strip()
        return body.strip(), ""
    return "", cell


def main():
    in_path = sys.argv[1] if len(sys.argv) > 1 else INPUT_DEFAULT
    out_path = sys.argv[2] if len(sys.argv) > 2 else OUTPUT_DEFAULT

    items = []
    with open(in_path, encoding="utf-8-sig", newline="") as f:
        reader = csv.reader(f)
        next(reader, None)  # 跳过表头
        for row in reader:
            if len(row) < 11:
                row = row + [""] * (11 - len(row))
            (update_time, company, deadline, rtype, cohort,
             ctype, roles, city, ann_url, apply_url, status) = row[:11]

            company = company.strip()
            if not company:
                continue

            industry, positions = parse_role(roles)
            raw = "||".join([company, update_time, deadline, rtype,
                             cohort, ctype, roles, city, ann_url, apply_url])
            uid = hashlib.md5(raw.encode("utf-8")).hexdigest()[:12]

            items.append({
                "id": uid,
                "company": company,
                "updatedAt": parse_date(update_time),
                "deadline": parse_date(deadline),
                "type": rtype.strip(),
                "targetCohort": cohort.strip(),
                "companyType": ctype.strip(),
                "industry": industry,
                "positions": positions,
                "city": city.strip(),
                "announcementUrl": ann_url.strip(),
                "applyUrl": apply_url.strip(),
                "status": status.strip(),
            })

    out = {
        "updatedAt": datetime.now().strftime("%Y-%m-%dT%H:%M:%S+08:00"),
        "count": len(items),
        "items": items,
    }
    with open(out_path, "w", encoding="utf-8") as f:
        json.dump(out, f, ensure_ascii=False, indent=2)
    print(f"已生成 {out_path}：共 {len(items)} 条")


if __name__ == "__main__":
    main()
