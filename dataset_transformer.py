import json
import gzip
from pathlib import Path
from typing import Any, Dict, List, Union, Optional, Iterable

Number = Union[int, float]


# CHANGE THIS BASE_DIR TO YOUR ACTUAL INSTANCE DIRECTORY
BASE_DIR = "/home/jxxiong/.julia/packages/UnitCommitment/nnguY/instances"

class PowerSystemDatasetTransformer:
    """
    电力系统 JSON 数据集转换器（默认优先处理 .json.gz，输出也压缩为 .json.gz）。

    转换规则：
      Parameters:
        - "Power balance penalty ($/MW)" ÷4
        - "Time horizon (h)" ×4
      Generators:
        - "Startup delays (h)" ×4
        - "Ramp up limit (MW)" ÷4
        - "Ramp down limit (MW)" ÷4
        - "Production cost curve ($)" ÷4
        - "Minimum uptime (h)" ×4
        - "Minimum downtime (h)" ×4
        - "Initial status (h)" ×4
      Buses:
        - "Load (MW)":
            复制模式（默认）：
              * 标量 == 0 -> 保持 0
              * 标量 != 0 -> [v]*4
              * 列表 -> 元素级复制 4 次（长度变为 4N）
            插值模式（--interpolate）：
              * 列表：先对相邻数据间插入 3 个线性点（长度 4N-3），再用最后两个点向外外推 3 点（总长 4N）
              * 标量 == 0 -> 保持 0
              * 标量 != 0 -> 退化为 [v]*4
      Reserves:
        - "Amount (MW)" 同上规则（复制或插值由 flag 控制）

    读取：
        - 支持 *.json.gz 与 *.json
        - 默认只扫描 *.json.gz，--both 可同时扫描
        - 同名 file.json 与 file.json.gz 并存时仅处理压缩版

    输出（本版本改动）：
        - 默认输出压缩：xxx.json.gz
          * 输入 a.json.gz  -> 输出 a.json.gz
          * 输入 a.json     -> 输出 a.json.gz
          * 输入 a.data     -> 输出 a.data.json.gz
        - 可通过 compress_output=False / CLI 的 --no-compress 改为输出未压缩 .json
    """

    REPLICATION_FACTOR = 4  # 子小时分辨率（4 倍）
    EXTRAPOLATE_AFTER = REPLICATION_FACTOR - 1  # 插值后再向外补的点数（3）

    # ---- Key 常量 ----
    LOAD_KEY = "Load (MW)"
    RESERVE_AMOUNT_KEY = "Amount (MW)"

    PARAM_PENALTY_KEY = "Power balance penalty ($/MW)"
    PARAM_TIME_KEY = "Time horizon (h)"

    GEN_STARTUP_DELAYS_KEY = "Startup delays (h)"
    GEN_RAMP_UP_KEY = "Ramp up limit (MW)"
    GEN_RAMP_DOWN_KEY = "Ramp down limit (MW)"
    GEN_MIN_UPTIME_KEY = "Minimum uptime (h)"
    GEN_MIN_DOWNTIME_KEY = "Minimum downtime (h)"
    GEN_INITIAL_STATUS_KEY = "Initial status (h)"
    GEN_PROD_COST_CURVE_P_KEY = "Production cost curve ($)"

    @classmethod
    def transform_folder(
        cls,
        src_dir: str,
        dst_dir: str,
        glob_pattern: Optional[str] = None,
        both: bool = False,
        overwrite: bool = True,
        recursive: bool = False,
        verbose: bool = True,
        compress_output: bool = True,
        encoding: str = "utf-8",
        gzip_compresslevel: int = 5,
        interpolate: bool = False,
    ) -> None:
        """
        转换目录下文件。

        参数
        ----
        src_dir : 输入目录
        dst_dir : 输出目录（自动创建）
        glob_pattern : 自定义匹配模式；None 时使用默认策略
        both : 是否同时扫描 .json.gz 与 .json
        overwrite : 是否覆盖已存在输出
        recursive : 是否递归（若 True 且 pattern 未含 ** 则自动加 **/ 前缀）
        verbose : 是否打印日志
        compress_output : True 输出 .json.gz；False 输出普通 .json
        encoding : 文本编码
        gzip_compresslevel : gzip 压缩等级 0-9
        interpolate : 是否对 Buses/Reserves 使用线性插值（默认 False 为直接复制）
        """
        src_path = Path(src_dir)
        dst_path = Path(dst_dir)
        if not src_path.exists() or not src_path.is_dir():
            raise NotADirectoryError(f"源目录不存在或不是目录: {src_dir}")
        dst_path.mkdir(parents=True, exist_ok=True)

        # 构造扫描模式
        if glob_pattern:
            patterns = [glob_pattern]
        else:
            patterns = ["*.json.gz"] if not both else ["*.json.gz", "*.json"]

        # 收集文件
        files: List[Path] = []
        for pattern in patterns:
            if recursive and "**" not in pattern:
                files.extend(src_path.glob("**/" + pattern))
            else:
                files.extend(src_path.glob(pattern))

        if not files:
            if verbose:
                print(f"[INFO] 未找到匹配文件 模式={patterns} 目录={src_dir}")
            return

        selected = cls._deduplicate_files(files)
        if verbose:
            print(f"[INFO] 原始匹配 {len(files)} 个，去重后 {len(selected)} 个待处理。")

        for file in selected:
            rel = file.relative_to(src_path)
            try:
                data = cls._load_json_any(file, encoding=encoding)
            except Exception as e:
                print(f"[ERROR] 读取失败 {rel}: {e}")
                continue

            try:
                transformed = cls.transform_data(data, interpolate_series=interpolate)
            except Exception as e:
                print(f"[ERROR] 转换失败 {rel}: {e}")
                continue

            out_name = cls._derive_output_name(file, compress_output=compress_output)
            out_file = dst_path / out_name

            if out_file.exists() and not overwrite:
                if verbose:
                    print(f"[SKIP] 已存在且不覆盖: {out_file}")
                continue

            try:
                cls._write_output(
                    out_file,
                    transformed,
                    compress=compress_output,
                    encoding=encoding,
                    gzip_compresslevel=gzip_compresslevel
                )
                if verbose:
                    print(f"[OK] {rel} -> {out_file.name}")
            except Exception as e:
                print(f"[ERROR] 写入失败 {out_file}: {e}")

    # ---------- 文件辅助 ----------

    @staticmethod
    def _deduplicate_files(files: Iterable[Path]) -> List[Path]:
        """
        若存在 name.json 与 name.json.gz，只保留 .json.gz。
        """
        chosen: Dict[str, Path] = {}
        for f in files:
            name = f.name
            if name.endswith(".json.gz"):
                key = name[:-8]
            elif name.endswith(".json"):
                key = name[:-5]
            else:
                key = name
            if key in chosen:
                old = chosen[key]
                if old.name.endswith(".json") and name.endswith(".json.gz"):
                    chosen[key] = f
            else:
                chosen[key] = f
        return list(chosen.values())

    @classmethod
    def _derive_output_name(cls, path: Path, compress_output: bool) -> str:
        """
        根据压缩策略生成输出文件名。
        compress_output=True -> 统一以 .json.gz 结尾
        compress_output=False -> 统一以 .json 结尾
        """
        name = path.name
        if compress_output:
            # 目标：xxx.json.gz
            if name.endswith(".json.gz"):
                return name  # 已符合
            if name.endswith(".json"):
                return name + ".gz"  # 加 gz
            # 其它扩展
            return name + ".json.gz"
        else:
            # 输出普通 .json
            if name.endswith(".json.gz"):
                return name[:-3]  # 去掉 .gz
            if name.endswith(".json"):
                return name
            return name + ".json"

    @classmethod
    def _load_json_any(cls, path: Path, encoding: str = "utf-8") -> Dict[str, Any]:
        if path.name.endswith(".json.gz"):
            with gzip.open(path, "rt", encoding=encoding) as f:
                return json.load(f)
        elif path.name.endswith(".json"):
            with path.open("r", encoding=encoding) as f:
                return json.load(f)
        else:
            raise ValueError(f"不支持的文件扩展: {path}")

    @staticmethod
    def _write_output(
        out_file: Path,
        data: Dict[str, Any],
        compress: bool,
        encoding: str = "utf-8",
        gzip_compresslevel: int = 5
    ) -> None:
        if compress:
            with gzip.open(out_file, "wt", encoding=encoding, compresslevel=gzip_compresslevel) as f:
                json.dump(data, f, ensure_ascii=False, indent=2)
        else:
            with out_file.open("w", encoding=encoding) as f:
                json.dump(data, f, ensure_ascii=False, indent=2)

    # ---------- 数据转换主入口 ----------

    @classmethod
    def transform_data(cls, data: Dict[str, Any], interpolate_series: bool = False) -> Dict[str, Any]:
        data = json.loads(json.dumps(data))  # 深拷贝
        cls._transform_parameters(data.get("Parameters"))
        cls._transform_generators(data.get("Generators"))
        cls._transform_buses(data.get("Buses"), interpolate=interpolate_series)
        cls._transform_reserves(data.get("Reserves"), interpolate=interpolate_series)
        return data

    # ---------- 各部分转换 ----------

    @classmethod
    def _transform_parameters(cls, params: Optional[Dict[str, Any]]) -> None:
        if not isinstance(params, dict):
            return
        if cls.PARAM_PENALTY_KEY in params and cls._is_number(params[cls.PARAM_PENALTY_KEY]):
            params[cls.PARAM_PENALTY_KEY] /= 4
        if cls.PARAM_TIME_KEY in params and cls._is_number(params[cls.PARAM_TIME_KEY]):
            params[cls.PARAM_TIME_KEY] *= 4

    @classmethod
    def _transform_generators(cls, generators: Optional[Dict[str, Any]]) -> None:
        if not isinstance(generators, dict):
            return
        for gen in generators.values():
            if not isinstance(gen, dict):
                continue
            if cls.GEN_STARTUP_DELAYS_KEY in gen:
                gen[cls.GEN_STARTUP_DELAYS_KEY] = cls._scale_list(gen[cls.GEN_STARTUP_DELAYS_KEY], 4, "mul")
            if cls.GEN_RAMP_UP_KEY in gen and cls._is_number(gen[cls.GEN_RAMP_UP_KEY]):
                gen[cls.GEN_RAMP_UP_KEY] /= 4
            if cls.GEN_RAMP_DOWN_KEY in gen and cls._is_number(gen[cls.GEN_RAMP_DOWN_KEY]):
                gen[cls.GEN_RAMP_DOWN_KEY] /= 4
            if cls.GEN_PROD_COST_CURVE_P_KEY in gen:
                gen[cls.GEN_PROD_COST_CURVE_P_KEY] = cls._scale_list(gen[cls.GEN_PROD_COST_CURVE_P_KEY], 4, "div")
            if cls.GEN_MIN_UPTIME_KEY in gen and cls._is_number(gen[cls.GEN_MIN_UPTIME_KEY]):
                gen[cls.GEN_MIN_UPTIME_KEY] *= 4
            if cls.GEN_MIN_DOWNTIME_KEY in gen and cls._is_number(gen[cls.GEN_MIN_DOWNTIME_KEY]):
                gen[cls.GEN_MIN_DOWNTIME_KEY] *= 4
            if cls.GEN_INITIAL_STATUS_KEY in gen and cls._is_number(gen[cls.GEN_INITIAL_STATUS_KEY]):
                gen[cls.GEN_INITIAL_STATUS_KEY] *= 4

    @classmethod
    def _transform_buses(cls, buses: Optional[Dict[str, Any]], interpolate: bool = False) -> None:
        if not isinstance(buses, dict):
            return
        for bus in buses.values():
            if isinstance(bus, dict) and cls.LOAD_KEY in bus:
                series = bus[cls.LOAD_KEY]
                if interpolate:
                    bus[cls.LOAD_KEY] = cls._interpolate_or_replicate_series(
                        series, replication=cls.REPLICATION_FACTOR, extend=cls.EXTRAPOLATE_AFTER
                    )
                else:
                    bus[cls.LOAD_KEY] = cls._replicate_series(series, cls.REPLICATION_FACTOR)

    @classmethod
    def _transform_reserves(cls, reserves: Optional[Dict[str, Any]], interpolate: bool = False) -> None:
        if not isinstance(reserves, dict):
            return
        for reserve in reserves.values():
            if isinstance(reserve, dict) and cls.RESERVE_AMOUNT_KEY in reserve:
                series = reserve[cls.RESERVE_AMOUNT_KEY]
                if interpolate:
                    reserve[cls.RESERVE_AMOUNT_KEY] = cls._interpolate_or_replicate_series(
                        series, replication=cls.REPLICATION_FACTOR, extend=cls.EXTRAPOLATE_AFTER
                    )
                else:
                    reserve[cls.RESERVE_AMOUNT_KEY] = cls._replicate_series(series, cls.REPLICATION_FACTOR)

    # ---------- 工具函数 ----------

    @staticmethod
    def _is_number(x: Any) -> bool:
        return isinstance(x, (int, float)) and not isinstance(x, bool)

    @staticmethod
    def _scale_list(values: Any, factor: Number, op: str) -> Any:
        def scale(v):
            if isinstance(v, (int, float)):
                return v * factor if op == "mul" else v / factor
            return v
        if isinstance(values, list):
            return [scale(v) for v in values]
        if isinstance(values, (int, float)):
            return scale(values)
        return values

    @classmethod
    def _replicate_series(cls, series: Any, replication: int) -> Any:
        if isinstance(series, list):
            out: List[Any] = []
            for v in series:
                out.extend([v] * replication)
            return out
        if isinstance(series, (int, float)) and series == 0:
            return series
        return [series] * replication

    @classmethod
    def _interpolate_or_replicate_series(cls, series: Any, replication: int, extend: int) -> Any:

        if not isinstance(series, list):
            if isinstance(series, (int, float)):
                if series == 0:
                    return series
                return [series] * replication
            return series

        n = len(series)
        if n == 0:
            return series
        if n == 1:
            v = series[0]
            if isinstance(v, (int, float)):
                return [v] * replication
            return series * replication

        out: List[Number] = []
        for i in range(n - 1):
            a = series[i]
            b = series[i + 1]
            if not (isinstance(a, (int, float)) and isinstance(b, (int, float))):
                out.extend([a] * replication)
                continue
            step = (b - a) / replication
            for k in range(replication):
                out.append(a + step * k)
        out.append(series[-1])

        if len(out) >= 2 and extend > 0:
            last = out[-1]
            prev = out[-2]
            if isinstance(last, (int, float)) and isinstance(prev, (int, float)):
                d = last - prev
                for _ in range(extend):
                    last = last + d
                    out.append(last)
            else:
                pass

        return out

if __name__ == "__main__":
    import argparse

    parser = argparse.ArgumentParser(description="转换电力系统数据（默认输入 *.json.gz，输出压缩 .json.gz）。")
    # parser.add_argument("src", help="源目录")
    # parser.add_argument("dst", help="目标目录")
    parser.add_argument("--dataset", type=str, help="Instance name, e.g., case14")
    parser.add_argument("--pattern", help="自定义 glob 模式（覆盖默认策略）")
    parser.add_argument("--both", action="store_true", help="同时扫描 .json 与 .json.gz")
    parser.add_argument("--recursive", action="store_true", help="递归子目录")
    parser.add_argument("--no-overwrite", action="store_true", help="不覆盖已存在输出文件")
    parser.add_argument("--no-compress", action="store_true", help="输出不压缩（写出纯 .json）")
    parser.add_argument("--quiet", action="store_true", help="安静模式")
    parser.add_argument("--compress-level", type=int, default=5, help="gzip 压缩等级 0-9 (默认 5)")
    parser.add_argument(
        "--interpolate",
        action="store_true",
        help="对 Buses/Reserves 使用线性插值（相邻间插入3点，末端再外推3点）；默认为直接复制。"
    )

    args = parser.parse_args()
    
    # parent_dir = ""
    instance_name = args.dataset
    
    src = f"{BASE_DIR}/matpower/{instance_name}"
    dst = f"{BASE_DIR}/matpower_subhour/{instance_name}"
    PowerSystemDatasetTransformer.transform_folder(
        src_dir=src,
        dst_dir=dst,
        glob_pattern=args.pattern,
        both=args.both,
        overwrite=not args.no_overwrite,
        recursive=args.recursive,
        verbose=not args.quiet,
        compress_output=not args.no_compress,
        gzip_compresslevel=args.compress_level,
        interpolate=args.interpolate,
    )