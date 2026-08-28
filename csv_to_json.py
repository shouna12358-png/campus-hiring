#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
将「招聘信息源.csv」转换为 GPT Action 可消费的 campus-hiring.json。

用法:
    python csv_to_json.py [输入csv] [输出json]
默认输入: E:/数据源/招聘信息源.csv
默认输出: campus-hiring.json (当前目录)

字段映射（优先按 CSV 表头识别，兼容旧版 11 列格式）:
    更新时间、公司名称、截止时间、招聘类型、目前人群、公司类型、城市、公告链接、
    投递链接、投递状态、开招时间、行业归类、招聘岗位提取
"""
import csv
import sys
import json
import hashlib
import re
from datetime import datetime

INPUT_DEFAULT = "E:/数据源/招聘信息源.csv"
OUTPUT_DEFAULT = "campus-hiring.json"

TYPE_ORDER = {
    "春招": 0,
    "春招补录": 1,
    "夏招": 2,
    "秋招": 3,
    "秋招提前批": 4,
    "实习": 5,
    "校招": 6,
    "公开招聘": 7,
    "专岗": 8,
}


def normalize_recruitment_type_tags(value: str):
    """将招聘类型拆分为标准化标签列表，保留组合类型的语义。"""
    raw = (value or "").strip()
    if not raw:
        return []

    aliases = {
        "春季招聘": "春招",
        "春季校招": "春招",
        "春招补录批": "春招补录",
        "秋季招聘": "秋招",
        "秋季校招": "秋招",
        "秋招提前批次": "秋招提前批",
        "实习招聘": "实习",
        "校园招聘": "校招",
    }
    tokens = []
    for token in re.split(r"[,，、/／|｜;；+]+", raw):
        token = re.sub(r"^\s+|\s+$", "", token)
        if not token:
            continue
        # 年份是批次信息，不应生成新的筛选类型，如“26秋招”统一为“秋招”。
        token = re.sub(r"^(?:20\d{2}|2\d)(?:届)?年?", "", token)
        token = aliases.get(token, token)
        if token and token not in tokens:
            tokens.append(token)
    tokens.sort(key=lambda item: (TYPE_ORDER.get(item, 999), item))
    return tokens


def normalize_recruitment_type(value: str) -> str:
    """统一招聘类型分隔符、别名和顺序，同时保留多类型标签。"""
    return ",".join(normalize_recruitment_type_tags(value))


def normalize_tags(value: str):
    """把 CSV 的“标签”列拆分为去重后的 JSON 标签数组。"""
    tags = []
    for tag in re.split(r"[,，、|｜;；]+", (value or "").strip()):
        tag = tag.strip()
        if tag and tag not in tags:
            tags.append(tag)
    return tags


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


def clean_header(value: str) -> str:
    """去除表头首尾空白及空格，便于兼容 Excel 的轻微表头差异。"""
    return "".join((value or "").strip().split())


def find_column(header, *names, prefix=False):
    """按表头名称查找列，必要时允许名称后带说明文字。"""
    normalized = [clean_header(value) for value in header]
    targets = [clean_header(name) for name in names]
    for target in targets:
        for index, value in enumerate(normalized):
            if value == target or (prefix and value.startswith(target)):
                return index
    return None


def require_column(header, *names, prefix=False):
    index = find_column(header, *names, prefix=prefix)
    if index is None:
        expected = " / ".join(names)
        raise ValueError(f"CSV 缺少必要列：{expected}；实际表头：{header}")
    return index


def main():
    in_path = sys.argv[1] if len(sys.argv) > 1 else INPUT_DEFAULT
    out_path = sys.argv[2] if len(sys.argv) > 2 else OUTPUT_DEFAULT

    items = []
    # 兼容 UTF-8 / GB18030 等 CSV 编码。
    # GB18030 是 GBK/GB2312 的超集，放在 GBK 前面可以避免把
    # 仅首行可解码的文件误判为 GBK。
    f = None
    detected_encoding = None
    for enc in ("utf-8-sig", "utf-8", "gb18030"):
        try:
            # 必须完整读取并解析一次，不能只验证表头；否则可能在
            # 后续记录遇到 GB18030 特有字符时才抛出 UnicodeDecodeError。
            with open(in_path, encoding=enc, newline="") as candidate:
                list(csv.reader(candidate))
            f = open(in_path, encoding=enc, newline="")
            detected_encoding = enc
            break
        except (UnicodeDecodeError, UnicodeError):
            if f:
                f.close()
                f = None
            continue
    if f is None:
        raise ValueError(
            f"无法识别 {in_path} 的字符编码，请先用 Excel/记事本另存为 UTF-8 或 GB18030 CSV"
        )

    print(f"Detected CSV encoding: {detected_encoding}")

    with f:
        reader = csv.reader(f)
        header = next(reader, None)
        if not header:
            raise ValueError(f"CSV 没有表头：{in_path}")

        update_idx = require_column(header, "更新时间")
        company_idx = require_column(header, "公司名称")
        deadline_idx = require_column(header, "截止时间")
        rtype_idx = require_column(header, "招聘类型", prefix=True)
        cohort_idx = require_column(header, "目前人群", prefix=True)
        ctype_idx = require_column(header, "公司类型", prefix=True)
        city_idx = require_column(header, "城市")
        ann_idx = require_column(header, "公告链接")
        apply_idx = require_column(header, "投递链接")
        status_idx = require_column(header, "投递状态")

        open_at_idx = find_column(header, "开招时间")
        industry_idx = find_column(header, "行业归类")
        positions_idx = find_column(header, "招聘岗位提取")
        tags_idx = find_column(header, "标签")
        roles_idx = find_column(header, "招聘岗位")

        if (industry_idx is None) != (positions_idx is None):
            raise ValueError("CSV 必须同时包含“行业归类”和“招聘岗位提取”列")
        if industry_idx is None:
            if roles_idx is None:
                raise ValueError("CSV 缺少“行业归类/招聘岗位提取”或旧版“招聘岗位”列")
            max_idx = max(
                update_idx, company_idx, deadline_idx, rtype_idx, cohort_idx,
                ctype_idx, city_idx, ann_idx, apply_idx, status_idx, roles_idx
            )
        else:
            max_idx = max(
                update_idx, company_idx, deadline_idx, rtype_idx, cohort_idx,
                ctype_idx, city_idx, ann_idx, apply_idx, status_idx,
                industry_idx, positions_idx
            )
        if open_at_idx is not None:
            max_idx = max(max_idx, open_at_idx)
        if tags_idx is not None:
            max_idx = max(max_idx, tags_idx)

        for row in reader:
            if len(row) <= max_idx:
                row = row + [""] * (max_idx + 1 - len(row))

            update_time = row[update_idx]
            company = row[company_idx]
            deadline = row[deadline_idx]
            rtype = row[rtype_idx]
            cohort = row[cohort_idx]
            ctype = row[ctype_idx]
            city = row[city_idx]
            ann_url = row[ann_idx]
            apply_url = row[apply_idx]
            status = row[status_idx]
            open_at = row[open_at_idx] if open_at_idx is not None else ""
            tags = normalize_tags(row[tags_idx]) if tags_idx is not None else []

            company = company.strip()
            if not company:
                continue

            if industry_idx is not None:
                industry = row[industry_idx].strip()
                positions = row[positions_idx].strip()
            else:
                industry, positions = parse_role(row[roles_idx])

            raw = "||".join([
                update_time, company, deadline, rtype, cohort, ctype, city,
                ann_url, apply_url, status, open_at, industry, positions
            ])
            uid = hashlib.md5(raw.encode("utf-8")).hexdigest()[:12]

            type_tags = normalize_recruitment_type_tags(rtype)

            items.append({
                "id": uid,
                "company": company,
                "updatedAt": parse_date(update_time),
                "deadline": parse_date(deadline),
                # Keep the combined string for backward compatibility, and
                # expose split tags for UI filters that need semantic options.
                "type": ",".join(type_tags),
                "typeTags": type_tags,
                "tags": tags,
                "targetCohort": cohort.strip(),
                "companyType": ctype.strip(),
                "industry": industry,
                "positions": positions,
                "city": city.strip(),
                "announcementUrl": ann_url.strip(),
                "applyUrl": apply_url.strip(),
                "status": status.strip(),
                "openAt": open_at.strip(),
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
