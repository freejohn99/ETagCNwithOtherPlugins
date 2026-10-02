#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
run_etagcn_batches.py —— 用 LANraragi 官方 HTTP API，为“没有有效标签”的漫画补全中文标签

说明：
  - 档案列表由 /api/archives 一次性返回，批处理完全在脚本端，所以不按批处理，直接遍历全部目标档案。
  - 目标档案：标签里只有自动元数据（默认 date_added/timestamp），没有任何有效标签。
  - 每个档案按插件优先级依次尝试：etagcn -> wnacgcn -> picacgcn，命中即停。
  - 每处理一个档案之间会等待 --delay 秒，避免被服务端当成爬虫。

每个档案的处理流程（等价于编辑页“运行插件 + 保存元数据”）：
  1. POST /api/plugins/use?plugin=<ns>&id=<arcid>&arg=   —— 运行插件，取回 data.new_tags
  2. GET  /api/archives/<arcid>/metadata                 —— 取现有 tags/title/summary
  3. PUT  /api/archives/<arcid>/metadata                 —— 合并新标签后写回

认证（见 LRR Utils/Login.pm）：Authorization: Bearer <base64(api_key)>（兼容 ?key=）

环境：conda 环境 "jav"（需 requests）。示例：
  conda run -n jav --no-capture-output python tools/run_etagcn_batches.py --base-url http://127.0.0.1:3000 --api-key default_api_key --dry-run
  conda run -n jav --no-capture-output python tools/run_etagcn_batches.py --base-url http://127.0.0.1:3000 --api-key default_api_key --delay 5
  # 强制更新所有档案（已有标签的只补缺失部分），忽略进度记录与“仅有自动标签”过滤
  conda run -n jav --no-capture-output python tools/run_etagcn_batches.py --base-url http://127.0.0.1:3000 --api-key default_api_key --delay 5 --force

进度文件默认保存在“当前目录”下的 .etagcn_progress.json（可用 --state-file 指定）。
"""

from __future__ import annotations

import argparse
import base64
import json
import os
import re
import sys
import time
from pathlib import Path
from typing import Any, Dict, List, Optional

try:
    import requests
except ImportError:  # pragma: no cover
    sys.stderr.write("需要 requests：conda run -n jav pip install requests\n")
    raise

DEFAULT_BASE_URL = os.environ.get("LRR_BASE_URL", "http://127.0.0.1:3000")
DEFAULT_API_KEY = os.environ.get("LRR_API_KEY", "default_api_key")
SCRIPT_VERSION = "2.2"
# 插件优先级：优先 etagcn，其次 wnacgcn，最后 picacgcn
DEFAULT_PLUGINS = os.environ.get("ETAGCN_PLUGINS", "etagcn,wnacgcn,picacgcn")
# 视为“自动元数据、不算有效标签”的命名空间
DEFAULT_IGNORE_NS = "date_added,timestamp"

# 标题里“以 gid 开头”的匹配：如 "4210316-[ひし形とまる] ..."
DEFAULT_GID_RE = r"^\s*(\d{4,})\s*-"
# 次优先：被中/圆括号包裹的 gid，如 "[4210316] ..." / "(4210316)"
BRACKET_GID_RE = re.compile(r"[\[\(]\s*(\d{4,})\s*[\]\)]")


def log(*parts: Any) -> None:
    """带系统时间戳的日志输出，方便定位运行时间。"""
    sys.stdout.write(time.strftime("[%Y-%m-%d %H:%M:%S] ") + " ".join(str(p) for p in parts) + "\n")
    sys.stdout.flush()


# --------------------------------------------------------------------------- #
# 基础 HTTP
# --------------------------------------------------------------------------- #
def make_session(api_key: str, use_env_proxy: bool = False, connect_timeout: float = 10.0) -> requests.Session:
    session = requests.Session()
    # LRR 通常在局域网内，默认忽略系统 HTTP(S)_PROXY，避免被代理绕一圈
    session.trust_env = use_env_proxy
    session._connect_timeout = connect_timeout  # type: ignore[attr-defined]
    token = base64.b64encode(api_key.encode("utf-8")).decode("ascii")
    session.headers["Authorization"] = f"Bearer {token}"
    session.headers["User-Agent"] = "etagcn-batch-runner/2.0"
    session.headers["Accept"] = "application/json"
    return session


def request_json(
    session: requests.Session,
    method: str,
    url: str,
    *,
    timeout: float,
    retries: int,
    **kwargs: Any,
) -> Any:
    """带重试的请求；非 2xx 抛异常。"""
    last_exc: Optional[Exception] = None
    ct = getattr(session, "_connect_timeout", None)
    tmo = (ct, timeout) if ct else timeout  # (连接超时, 读取超时)
    for attempt in range(retries + 1):
        try:
            resp = session.request(method, url, timeout=tmo, **kwargs)
            if resp.status_code >= 400:
                raise requests.HTTPError(f"HTTP {resp.status_code}: {resp.text[:200]}")
            if not resp.content:
                return None
            return resp.json()
        except Exception as exc:  # noqa: BLE001
            last_exc = exc
            if attempt < retries:
                time.sleep(1.5 * (attempt + 1))
    raise RuntimeError(str(last_exc))


def get_archives(session: requests.Session, base: str, timeout: float, retries: int) -> List[Dict[str, str]]:
    data = request_json(session, "GET", f"{base}/api/archives", timeout=timeout, retries=retries)
    archives: List[Dict[str, str]] = []
    for item in data or []:
        if isinstance(item, str):
            archives.append({"arcid": item, "title": "", "tags": ""})
        else:
            arcid = item.get("arcid") or item.get("id")
            if not arcid:
                continue
            archives.append(
                {
                    "arcid": arcid,
                    "title": item.get("title") or "",
                    "tags": item.get("tags") or "",
                }
            )
    return archives


def run_plugin(
    session: requests.Session, base: str, plugin: str, arcid: str, timeout: float, retries: int
) -> Dict[str, Any]:
    return request_json(
        session,
        "POST",
        f"{base}/api/plugins/use",
        timeout=timeout,
        retries=retries,
        params={"plugin": plugin, "id": arcid, "arg": ""},
    ) or {}


def get_metadata(session: requests.Session, base: str, arcid: str, timeout: float, retries: int) -> Dict[str, Any]:
    return request_json(
        session, "GET", f"{base}/api/archives/{arcid}/metadata", timeout=timeout, retries=retries
    ) or {}


def save_metadata(
    session: requests.Session,
    base: str,
    arcid: str,
    title: str,
    tags: str,
    summary: str,
    timeout: float,
    retries: int,
) -> Dict[str, Any]:
    return request_json(
        session,
        "PUT",
        f"{base}/api/archives/{arcid}/metadata",
        timeout=timeout,
        retries=retries,
        data={"title": title or "", "tags": tags or "", "summary": summary or ""},
    ) or {}


# --------------------------------------------------------------------------- #
# 标签 / gid 工具
# --------------------------------------------------------------------------- #
def split_tags(raw: Optional[str]) -> List[str]:
    if not raw:
        return []
    return [t.strip() for t in str(raw).split(",") if t.strip()]


def merge_tags(existing: Optional[str], new: Optional[str]) -> str:
    seen = set()
    ordered: List[str] = []
    for tag in split_tags(existing) + split_tags(new):
        key = tag.casefold()
        if key not in seen:
            seen.add(key)
            ordered.append(tag)
    return ", ".join(ordered)


def tag_namespace(tag: str) -> str:
    return tag.split(":", 1)[0].strip().lower() if ":" in tag else tag.strip().lower()


def has_only_ignored_tags(archive: Dict[str, str], ignore_ns: set) -> bool:
    """标签里除忽略命名空间外没有任何内容 => 视为“无有效标签”。"""
    for tag in split_tags(archive.get("tags")):
        if tag_namespace(tag) not in ignore_ns:
            return False
    return True


def detect_gid(title: str, gid_re: re.Pattern) -> Optional[str]:
    """标题里优先取“以 gid 开头”的编号，其次取括号包裹的编号。"""
    if not title:
        return None
    m = gid_re.match(title)
    if m:
        return m.group(1)
    m = BRACKET_GID_RE.search(title)
    if m:
        return m.group(1)
    return None


# --------------------------------------------------------------------------- #
# 进度持久化
# --------------------------------------------------------------------------- #
def load_state(path: Path) -> Dict[str, Any]:
    if path.is_file():
        try:
            return json.loads(path.read_text(encoding="utf-8"))
        except Exception:  # noqa: BLE001
            return {"done": []}
    return {"done": []}


def save_state(path: Path, state: Dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_suffix(path.suffix + ".tmp")
    tmp.write_text(json.dumps(state, ensure_ascii=False, indent=2), encoding="utf-8")
    tmp.replace(path)


# --------------------------------------------------------------------------- #
# 主流程
# --------------------------------------------------------------------------- #
def build_queue(
    archives: List[Dict[str, str]],
    gid_re: re.Pattern,
    gid_first: bool,
    gid_only: bool,
    ignore_ns: set,
    done_ids: set,
    force: bool = False,
) -> List[Dict[str, str]]:
    queued: List[Dict[str, str]] = []
    for arc in archives:
        # --force：忽略进度记录与“仅有自动标签”过滤，强制处理所有档案
        if not force and arc["arcid"] in done_ids:
            continue
        if not force and not has_only_ignored_tags(arc, ignore_ns):
            continue  # 已有有效标签，跳过
        gid = detect_gid(arc["title"], gid_re)
        if gid_only and not gid:
            continue
        arc["_gid"] = gid
        queued.append(arc)

    if gid_first:
        def sort_key(a: Dict[str, str]):
            gid = a.get("_gid")
            if gid:
                return (0, -int(gid), "")  # 有 gid 的优先，gid 越大通常越新
            return (1, 0, a["title"])

        queued.sort(key=sort_key)
    return queued


def process_one(
    session: requests.Session,
    base: str,
    plugins: List[str],
    arc: Dict[str, str],
    args: argparse.Namespace,
) -> Dict[str, Any]:
    """按插件优先级依次尝试，命中即停。
    返回 {'status': ok|nochange|error, 'plugin': str, 'added': int, 'error': str}
    ok=有新增并已写回；nochange=插件跑通但没有可补的新标签；error=所有插件都失败
    """
    errors: List[str] = []
    attempted: List[str] = []
    any_success = False

    def note(msg: str) -> None:
        if args.verbose:
            log(f"      [skip] {msg}")

    def fail(msg: str) -> None:
        errors.append(msg)
        note(msg)

    for plugin in plugins:
        attempted.append(plugin)
        try:
            result = run_plugin(session, base, plugin, arc["arcid"], args.timeout, args.retries)
        except Exception as exc:  # noqa: BLE001
            fail(f"{plugin}: {exc}")
            continue

        if not result or result.get("success") == 0:
            fail(f"{plugin}: {(result or {}).get('error') or 'no result'}")
            continue

        data = result.get("data") or {}
        if isinstance(data, dict) and data.get("error"):
            fail(f"{plugin}: {data['error']}")
            continue

        # 插件成功运行（即使没有新标签，也算这个档案处理过）
        any_success = True

        new_tags = (data.get("new_tags") or "") if isinstance(data, dict) else ""
        plugin_title = (data.get("title") or "") if isinstance(data, dict) else ""

        if not split_tags(new_tags) and not plugin_title:
            note(f"{plugin}: 无新标签")
            continue

        # 命中：合并写回（只追加当前标签表里没有的部分）
        meta = get_metadata(session, base, arc["arcid"], args.timeout, args.retries)
        merged = merge_tags(meta.get("tags"), new_tags)
        title = plugin_title or meta.get("title") or arc["title"]
        summary = meta.get("summary") or ""
        save_metadata(session, base, arc["arcid"], title, merged, summary, args.timeout, args.retries)
        return {"status": "ok", "plugin": plugin, "added": len(split_tags(new_tags)), "attempted": attempted}

    if any_success:
        return {"status": "nochange", "attempted": attempted}
    if errors:
        return {"status": "error", "error": "; ".join(errors), "attempted": attempted}
    return {"status": "nochange", "attempted": attempted}


def main() -> int:
    parser = argparse.ArgumentParser(
        description="用 LANraragi API 为无有效标签的漫画按插件优先级补全中文标签",
        formatter_class=argparse.ArgumentDefaultsHelpFormatter,
    )
    parser.add_argument("--base-url", default=DEFAULT_BASE_URL, help="LANraragi 地址（含可选 base path）")
    parser.add_argument("--api-key", default=DEFAULT_API_KEY, help="LANraragi API Key")
    parser.add_argument("--use-env-proxy", action="store_true",
                        help="使用系统 HTTP(S)_PROXY 访问 LRR（默认忽略，适合局域网直连）")
    parser.add_argument("--plugins", default=DEFAULT_PLUGINS,
                        help="按优先级排列的元数据插件 namespace，逗号分隔")
    parser.add_argument("--ignore-namespaces", default=DEFAULT_IGNORE_NS,
                        help="视为“自动元数据、不算有效标签”的命名空间（逗号分隔）")
    parser.add_argument("--delay", type=float, default=5.0, help="每个档案之间的等待秒数（避免被当成爬虫）")
    parser.add_argument("--limit", type=int, default=0, help="本次最多处理多少个档案（0 = 全部）")
    parser.add_argument("--timeout", type=float, default=60.0, help="单次 HTTP 请求的读取超时秒数")
    parser.add_argument("--connect-timeout", type=float, default=10.0, help="TCP 连接超时秒数（连不上时快速失败）")
    parser.add_argument("--retries", type=int, default=2, help="网络/5xx 失败重试次数")
    parser.add_argument("--verbose", "-v", action="store_true", help="显示插件优先级中每个被跳过插件的原因")
    parser.add_argument("--gid-only", action="store_true", help="只处理标题里含 gid 的档案")
    parser.add_argument("--no-gid-priority", dest="gid_first", action="store_false",
                        help="不做 gid 优先排序")
    parser.set_defaults(gid_first=True)
    parser.add_argument("--gid-regex", default=DEFAULT_GID_RE,
                        help='gid 前缀正则（默认匹配 "4210316-...")')
    parser.add_argument("--state-file", default=str(Path.cwd() / ".etagcn_progress.json"),
                        help="进度文件（默认当前目录下）")
    parser.add_argument("--force", action="store_true",
                        help="强制更新所有档案：忽略“仅有自动标签”过滤与进度记录；已有标签的只补缺失部分")
    parser.add_argument("--reset-state", action="store_true", help="清空进度后重新开始")
    parser.add_argument("--dry-run", action="store_true", help="只显示将要处理的档案，不实际执行")
    parser.add_argument("--list-limit", type=int, default=20, help="--dry-run 时最多显示多少条")

    args = parser.parse_args()

    # 控制台尽量正确显示日文/中文标题；行缓冲保证容器/管道下日志实时输出
    try:
        sys.stdout.reconfigure(encoding="utf-8", errors="replace", line_buffering=True)  # type: ignore[attr-defined]
    except Exception:  # noqa: BLE001
        pass

    log(f"[i] run_etagcn_batches.py v{SCRIPT_VERSION}")

    base = args.base_url.rstrip("/")
    gid_re = re.compile(args.gid_regex)
    plugins = [p.strip() for p in args.plugins.split(",") if p.strip()]
    ignore_ns = {n.strip().lower() for n in args.ignore_namespaces.split(",") if n.strip()}
    state_path = Path(args.state_file)
    session = make_session(args.api_key, args.use_env_proxy, args.connect_timeout)

    if args.reset_state and state_path.is_file():
        state_path.unlink()
        log(f"[i] 已清空进度文件 {state_path}")

    state = load_state(state_path)
    done_ids = set(state.get("done", []))

    log(f"[i] 连接 {base}")
    log(f"[i] 插件优先级: {' > '.join(plugins)}")
    log(f"[i] 忽略命名空间: {', '.join(sorted(ignore_ns))}")
    log(f"[i] 进度文件: {state_path}")
    try:
        log(f"[i] 正在请求 {base}/api/archives ...（连接超时 {args.connect_timeout:.0f}s / 读取超时 {args.timeout:.0f}s）")
        archives = get_archives(session, base, args.timeout, args.retries)
    except Exception as exc:  # noqa: BLE001
        log(f"[!] 无法访问 {base}/api/archives：{exc}")
        log("    排查建议：")
        log("    - 在 LRR 容器内运行时，请用 --base-url http://127.0.0.1:3000（容器内直连自身）")
        log("    - 在宿主机运行时才用局域网 IP；确认端口已发布为 0.0.0.0:3000")
        log("    - 脚本默认忽略 HTTP(S)_PROXY；若你的环境必须走代理，加 --use-env-proxy")
        log("    - 想更快暴露连接问题，可加 --connect-timeout 3")
        return 2
    log(f"[i] 共 {len(archives)} 个档案，进度文件中已完成 {len(done_ids)} 个")

    queue = build_queue(archives, gid_re, args.gid_first, args.gid_only, ignore_ns, done_ids, args.force)
    gid_count = sum(1 for a in queue if a.get("_gid"))
    if args.force:
        log(f"[i] 强制更新：待处理 {len(queue)} 个（含已有标签的档案，只补缺失标签；gid 前缀 {gid_count} 个优先）")
    else:
        log(f"[i] 无有效标签待处理 {len(queue)} 个（其中 gid 前缀 {gid_count} 个，将优先执行）")

    if args.limit > 0:
        queue = queue[: args.limit]
        log(f"[i] 本次限制处理 {len(queue)} 个（--limit {args.limit}）")

    if args.dry_run:
        log("[i] 前 %d 条处理顺序：" % min(args.list_limit, len(queue)))
        for i, arc in enumerate(queue[: args.list_limit], 1):
            gid = arc.get("_gid") or "-"
            log(f"  {i:>3}. [{gid:>8}] {arc['arcid']}  {arc['title'][:70]}")
        return 0

    if not queue:
        log("[i] 没有需要处理的档案。")
        return 0

    stats = {"ok": 0, "nochange": 0, "error": 0}
    processed = 0

    for arc in queue:
        processed += 1
        arcid = arc["arcid"]
        label = f"[{processed}/{len(queue)}] {arcid} {arc['title'][:60]}"
        try:
            outcome = process_one(session, base, plugins, arc, args)
            status = outcome["status"]
            stats[status] = stats.get(status, 0) + 1
            if status == "ok":
                attempted = outcome.get("attempted") or []
                prior = attempted[:-1]
                via = outcome.get("plugin")
                suffix = str(via) + (f"，回退自 {'/'.join(prior)}" if prior else "")
                log(f"{label}  ->  +{outcome.get('added', 0)} tags ({suffix})")
                done_ids.add(arcid)
            elif status == "nochange":
                log(f"{label}  ->  所有插件均无新标签")
                done_ids.add(arcid)
            else:
                log(f"{label}  ->  ERROR: {outcome.get('error')}")
        except Exception as exc:  # noqa: BLE001
            stats["error"] += 1
            log(f"{label}  ->  ERROR: {exc}")

        # 每处理一个就落盘，异常中断也能续跑
        state["done"] = sorted(done_ids)
        state["updated_at"] = int(time.time())
        save_state(state_path, state)

        if args.delay > 0 and processed < len(queue):
            time.sleep(args.delay)

    log("===== 汇总 =====")
    log(f"成功写入: {stats['ok']}   无新标签: {stats['nochange']}   失败: {stats['error']}")
    log(f"累计已完成: {len(done_ids)} / {len(archives)}")
    log(f"进度文件: {state_path}")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except KeyboardInterrupt:
        log("[i] 已中断，进度已保存，可重新运行续跑。")
        raise SystemExit(130)
