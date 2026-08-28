#!/usr/bin/env python3
"""Consolida os CSVs produzidos por uma campanha do teste de provisionamento MGC."""

from __future__ import annotations

import argparse
import csv
import math
import statistics
from collections import Counter, defaultdict
from datetime import datetime
from pathlib import Path
from typing import Any, Iterable


def parse_args() -> argparse.Namespace:
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("campaign_dir", type=Path)
    return p.parse_args()


def read_key_value(path: Path) -> dict[str, str]:
    data: dict[str, str] = {}
    for line in path.read_text(encoding="utf-8", errors="replace").splitlines():
        if "=" in line:
            key, value = line.split("=", 1)
            data[key.strip()] = value.strip()
    return data


def as_float(value: Any) -> float | None:
    if value is None:
        return None
    text = str(value).strip()
    if not text:
        return None
    try:
        return float(text)
    except ValueError:
        return None


def percentile(values: Iterable[float], p: float) -> float | None:
    vals = sorted(values)
    if not vals:
        return None
    if len(vals) == 1:
        return vals[0]
    pos = (len(vals) - 1) * p
    lo, hi = math.floor(pos), math.ceil(pos)
    if lo == hi:
        return vals[lo]
    return vals[lo] + (vals[hi] - vals[lo]) * (pos - lo)


def fmt_s(value: float | None) -> str:
    return "—" if value is None else f"{value:.3f}s"


def fmt_pct(value: float) -> str:
    return f"{value:.1f}%"


def stats(values: Iterable[float | None]) -> dict[str, float | None]:
    vals = [v for v in values if v is not None]
    if not vals:
        return {"min": None, "avg": None, "median": None, "p95": None, "max": None, "stdev": None}
    return {
        "min": min(vals),
        "avg": statistics.fmean(vals),
        "median": statistics.median(vals),
        "p95": percentile(vals, 0.95),
        "max": max(vals),
        "stdev": statistics.stdev(vals) if len(vals) > 1 else 0.0,
    }


def write_csv(path: Path, rows: list[dict[str, Any]], fieldnames: list[str]) -> None:
    with path.open("w", newline="", encoding="utf-8") as f:
        writer = csv.DictWriter(f, fieldnames=fieldnames, extrasaction="ignore")
        writer.writeheader()
        writer.writerows(rows)


def md_escape(value: Any) -> str:
    return str(value if value is not None else "").replace("|", "\\|").replace("\n", " ")


def main() -> int:
    args = parse_args()
    root = args.campaign_dir.resolve()
    if not root.is_dir():
        raise SystemExit(f"Diretório inexistente: {root}")

    config = read_key_value(root / "campanha.conf") if (root / "campanha.conf").exists() else {}
    metas = [read_key_value(p) for p in sorted((root / "meta").glob("slot-*.meta"))]

    execution_fields = [
        "slot", "status", "scheduled_at", "actual_start", "actual_end", "exit_code", "run_dir", "output_prefix"
    ]
    write_csv(root / "execucoes_campanha.csv", metas, execution_fields)

    resources: list[dict[str, Any]] = []
    for csv_path in sorted((root / "runs").glob("run-*/provisionamento-mgc-*.csv")):
        run_dir = csv_path.parent
        slot = ""
        parts = run_dir.name.split("-")
        if len(parts) >= 2:
            slot = parts[1]
        meta = next((m for m in metas if str(m.get("slot", "")).zfill(3) == slot), {})
        with csv_path.open(newline="", encoding="utf-8-sig", errors="replace") as f:
            for row in csv.DictReader(f):
                row["campaign_id"] = config.get("campaign_id", root.name)
                row["campaign_slot"] = meta.get("slot", slot.lstrip("0") or slot)
                row["campaign_scheduled_at"] = meta.get("scheduled_at", "")
                row["campaign_actual_start"] = meta.get("actual_start", "")
                row["campaign_exit_code"] = meta.get("exit_code", "")
                row["source_file"] = str(csv_path.relative_to(root))
                resources.append(row)

    resource_fields = [
        "campaign_id", "campaign_slot", "campaign_scheduled_at", "campaign_actual_start", "campaign_exit_code",
        "product", "target", "region", "availability_zone", "name", "id", "configuration", "result", "state", "status",
        "create_api_seconds", "ready_seconds", "total_test_seconds", "public_ip", "readiness_result", "started_at", "ready_at",
        "error_message", "source_file",
    ]
    write_csv(root / "consolidado_recursos.csv", resources, resource_fields)

    groups: dict[tuple[str, str], list[dict[str, Any]]] = defaultdict(list)
    for row in resources:
        groups[(row.get("product", ""), row.get("target", ""))].append(row)

    summary_rows: list[dict[str, Any]] = []
    for (product, target), rows in sorted(groups.items()):
        successes = [r for r in rows if r.get("result") == "success"]
        api = stats(as_float(r.get("create_api_seconds")) for r in successes)
        ready = stats(as_float(r.get("ready_seconds")) for r in successes)
        total = stats(as_float(r.get("total_test_seconds")) for r in successes)
        readiness = Counter(r.get("readiness_result", "") or "empty" for r in rows)
        results = Counter(r.get("result", "") or "empty" for r in rows)
        summary_rows.append({
            "product": product,
            "target": target,
            "attempts": len(rows),
            "successes": len(successes),
            "failures": len(rows) - len(successes),
            "success_rate_percent": round(100 * len(successes) / len(rows), 3) if rows else 0,
            "api_min_seconds": api["min"], "api_avg_seconds": api["avg"], "api_median_seconds": api["median"], "api_p95_seconds": api["p95"], "api_max_seconds": api["max"],
            "ready_min_seconds": ready["min"], "ready_avg_seconds": ready["avg"], "ready_median_seconds": ready["median"], "ready_p95_seconds": ready["p95"], "ready_max_seconds": ready["max"], "ready_stdev_seconds": ready["stdev"],
            "total_min_seconds": total["min"], "total_avg_seconds": total["avg"], "total_median_seconds": total["median"], "total_p95_seconds": total["p95"], "total_max_seconds": total["max"],
            "result_counts": "; ".join(f"{k}={v}" for k, v in sorted(results.items())),
            "readiness_counts": "; ".join(f"{k}={v}" for k, v in sorted(readiness.items())),
        })

    summary_fields = list(summary_rows[0].keys()) if summary_rows else [
        "product", "target", "attempts", "successes", "failures", "success_rate_percent"
    ]
    write_csv(root / "resumo_por_alvo.csv", summary_rows, summary_fields)

    executed = [m for m in metas if m.get("status") == "completed"]
    skipped = [m for m in metas if m.get("status", "").startswith("skipped")]
    auth_errors = [m for m in metas if m.get("status") == "auth_error"]
    success_rows = [r for r in resources if r.get("result") == "success"]
    failure_rows = [r for r in resources if r.get("result") != "success"]
    overall_ready = stats(as_float(r.get("ready_seconds")) for r in success_rows)
    overall_api = stats(as_float(r.get("create_api_seconds")) for r in success_rows)
    readiness_counter = Counter(r.get("readiness_result", "") or "empty" for r in resources)

    slowest = sorted(
        (r for r in success_rows if as_float(r.get("ready_seconds")) is not None),
        key=lambda r: as_float(r.get("ready_seconds")) or 0,
        reverse=True,
    )[:10]

    report = root / "analise_campanha.md"
    with report.open("w", encoding="utf-8") as f:
        f.write("# Análise da campanha de provisionamento MGC\n\n")
        f.write(f"- **Campanha:** `{md_escape(config.get('campaign_id', root.name))}`\n")
        f.write(f"- **Início planejado:** {md_escape(config.get('started_at', '—'))}\n")
        f.write(f"- **Intervalo:** {md_escape(config.get('interval_minutes', '—'))} minutos\n")
        f.write(f"- **Rodadas planejadas:** {md_escape(config.get('planned_runs', len(metas)))}\n")
        f.write(f"- **Rodadas executadas:** {len(executed)}\n")
        f.write(f"- **Rodadas ignoradas por sobreposição:** {len(skipped)}\n")
        f.write(f"- **Falhas de autenticação:** {len(auth_errors)}\n")
        f.write(f"- **Recursos medidos:** {len(resources)}\n\n")

        f.write("## Visão geral\n\n")
        success_rate = 100 * len(success_rows) / len(resources) if resources else 0
        f.write(f"- **Provisionamentos bem-sucedidos:** {len(success_rows)}/{len(resources)} ({fmt_pct(success_rate)})\n")
        f.write(f"- **Falhas de provisionamento:** {len(failure_rows)}\n")
        f.write(f"- **Tempo Pronto — mínimo:** {fmt_s(overall_ready['min'])}\n")
        f.write(f"- **Tempo Pronto — mediana:** {fmt_s(overall_ready['median'])}\n")
        f.write(f"- **Tempo Pronto — média:** {fmt_s(overall_ready['avg'])}\n")
        f.write(f"- **Tempo Pronto — p95:** {fmt_s(overall_ready['p95'])}\n")
        f.write(f"- **Tempo Pronto — máximo:** {fmt_s(overall_ready['max'])}\n")
        f.write(f"- **Tempo de resposta da API — média:** {fmt_s(overall_api['avg'])}\n\n")

        if readiness_counter:
            f.write("### Validação complementar\n\n")
            for key, count in sorted(readiness_counter.items()):
                f.write(f"- `{md_escape(key)}`: {count}\n")
            f.write("\n")

        f.write("## Comparação por alvo\n\n")
        f.write("| Produto | Alvo | Tentativas | Sucesso | Taxa | Pronto mín. | Mediana | Média | p95 | Máx. | Desvio padrão |\n")
        f.write("|---|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|\n")
        for row in summary_rows:
            f.write(
                f"| {md_escape(row['product'])} | {md_escape(row['target'])} | {row['attempts']} | {row['successes']} | "
                f"{row['success_rate_percent']:.1f}% | {fmt_s(row.get('ready_min_seconds'))} | {fmt_s(row.get('ready_median_seconds'))} | "
                f"{fmt_s(row.get('ready_avg_seconds'))} | {fmt_s(row.get('ready_p95_seconds'))} | {fmt_s(row.get('ready_max_seconds'))} | "
                f"{fmt_s(row.get('ready_stdev_seconds'))} |\n"
            )

        f.write("\n## Provisionamentos mais lentos\n\n")
        if slowest:
            f.write("| Rodada | Produto | Alvo | Recurso | ID | Pronto | API | Estado |\n")
            f.write("|---:|---|---|---|---|---:|---:|---|\n")
            for row in slowest:
                f.write(
                    f"| {md_escape(row.get('campaign_slot'))} | {md_escape(row.get('product'))} | {md_escape(row.get('target'))} | "
                    f"`{md_escape(row.get('name'))}` | `{md_escape(row.get('id') or '—')}` | {fmt_s(as_float(row.get('ready_seconds')))} | "
                    f"{fmt_s(as_float(row.get('create_api_seconds')))} | {md_escape(row.get('state'))}/{md_escape(row.get('status'))} |\n"
                )
        else:
            f.write("Nenhum provisionamento concluído.\n")

        f.write("\n## Falhas\n\n")
        if failure_rows:
            for row in failure_rows:
                f.write(
                    f"- Rodada {md_escape(row.get('campaign_slot'))}, **{md_escape(row.get('target'))}**: "
                    f"`{md_escape(row.get('result'))}` — {md_escape(row.get('error_message') or 'sem mensagem')}\n"
                )
        else:
            f.write("Nenhuma falha de provisionamento registrada.\n")

        f.write("\n## Arquivos gerados\n\n")
        f.write("- `consolidado_recursos.csv`: todas as medições individuais.\n")
        f.write("- `resumo_por_alvo.csv`: estatísticas por produto e região/AZ.\n")
        f.write("- `execucoes_campanha.csv`: situação de cada horário planejado.\n")
        f.write("- `analise_campanha.md`: este relatório.\n")

    print(f"Consolidação concluída: {report}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
