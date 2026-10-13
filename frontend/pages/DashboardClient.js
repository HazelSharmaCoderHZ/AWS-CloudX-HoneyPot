import { useCallback, useEffect, useState } from "react";
import {
  Chart as ChartJS,
  CategoryScale,
  LinearScale,
  PointElement,
  LineElement,
  BarElement,
  Tooltip,
  Legend,
} from "chart.js";
import { Line, Bar } from "react-chartjs-2";
import {
  health,
  getStats,
  getEvents,
  getCharts,
  getPipeline,
  getConfig,
} from "../lib/api";

ChartJS.register(
  CategoryScale,
  LinearScale,
  PointElement,
  LineElement,
  BarElement,
  Tooltip,
  Legend
);

const chartOptions = {
  responsive: true,
  maintainAspectRatio: false,
  plugins: { legend: { labels: { color: "#cbd5e1" } } },
  scales: {
    x: { ticks: { color: "#94a3b8" }, grid: { color: "#263449" } },
    y: { beginAtZero: true, ticks: { color: "#94a3b8" }, grid: { color: "#263449" } },
  },
};

export default function DashboardClient() {
  const [data, setData] = useState({});
  const [error, setError] = useState("");
  const [loading, setLoading] = useState(true);
  const [updated, setUpdated] = useState("");

  const refresh = useCallback(async () => {
    try {
      const results = await Promise.allSettled([
        getConfig(),
        health(),
        getStats(),
        getEvents({ limit: 25 }),
        getCharts(12),
        getPipeline(),
      ]);

      const keys = ["config", "health", "stats", "events", "charts", "pipeline"];
      const next = {};
      const failures = [];

      results.forEach((result, i) => {
        if (result.status === "fulfilled") next[keys[i]] = result.value;
        else failures.push(keys[i] + ": " + result.reason.message);
      });

      setData(next);
      setError(failures.join(" | "));
      setUpdated(new Date().toLocaleTimeString());
    } catch (e) {
      setError(e.message || "Unable to load dashboard.");
    } finally {
      setLoading(false);
    }
  }, []);

  useEffect(() => {
    refresh();
    const timer = setInterval(refresh, 30000);
    return () => clearInterval(timer);
  }, [refresh]);

  const stats = data.stats || {};
  const events = data.events?.events || [];
  const charts = data.charts || {};
  const pipeline = data.pipeline || {};
  const trend = charts.events_over_time || [];
  const ips = charts.top_ips || [];

  const cards = [
    ["Recorded events", stats.total_events ?? "—"],
    ["Unique source IPs", stats.unique_source_ips ?? "—"],
    ["Sessions", stats.unique_sessions ?? "—"],
    ["Credential attempts", stats.credential_attempts ?? "—"],
  ];

  return (
    <main className="min-h-screen bg-navy-950 text-slate-100">
      <header className="border-b border-slate-800 px-6 py-5">
        <div className="mx-auto flex w-full max-w-7xl flex-wrap items-center justify-between gap-4">
          <div>
            <p className="text-sm font-semibold text-cyan-400">AWS CLOUDX</p>
            <h1 className="text-2xl font-bold">Honeypot Security Dashboard</h1>
            <p className="mt-1 text-sm text-slate-400">
              Cowrie activity · LocalStack monitoring
            </p>
          </div>
          <div className="flex flex-wrap items-center gap-3 text-sm">
            <span className="rounded-full bg-amber-950 px-3 py-2 text-amber-300">
              {data.config?.mode || "Connecting…"}
            </span>
            <button
              onClick={refresh}
              className="rounded-lg bg-indigo-600 px-4 py-2 font-semibold hover:bg-indigo-500"
            >
              Refresh
            </button>
          </div>
        </div>
      </header>

      <div className="mx-auto w-full max-w-7xl space-y-6 px-6 py-7">
        

        {loading && <p className="text-slate-400">Loading dashboard data…</p>}
        {error && (
          <div className="rounded-lg border border-red-700 bg-red-950/50 p-4 text-sm text-red-200">
            Some data could not be loaded: {error}
          </div>
        )}

        <section className="grid grid-cols-1 gap-4 sm:grid-cols-2 xl:grid-cols-4">
          {cards.map(([label, value], i) => (
            <article
              key={label}
              className={
                i === 0 ? "kpi-card-primary" : "kpi-card"
              }
            >
              <p className="text-sm text-slate-400">{label}</p>
              <p className="kpi-value">{value}</p>
            </article>
          ))}
        </section>

        <section className="grid grid-cols-1 gap-6 lg:grid-cols-2">
          <article className="chart-panel">
            <h2 className="mb-5 font-semibold">Activity over time</h2>
            <div className="chart-box">
              {trend.length ? (
                <Line
                  data={{
                    labels: trend.map((x) => x.timestamp),
                    datasets: [{
                      label: "Events",
                      data: trend.map((x) => x.events),
                      borderColor: "#22d3ee",
                      backgroundColor: "#22d3ee",
                      tension: 0.3,
                    }],
                  }}
                  options={chartOptions}
                />
              ) : <p className="text-sm text-slate-500">No chart data available.</p>}
            </div>
          </article>

          <article className="chart-panel">
            <h2 className="mb-5 font-semibold">Top source IPs</h2>
            <div className="chart-box">
              {ips.length ? (
                <Bar
                  data={{
                    labels: ips.map((x) => x.src_ip),
                    datasets: [{
                      label: "Events",
                      data: ips.map((x) => x.events),
                      backgroundColor: "#818cf8",
                    }],
                  }}
                  options={chartOptions}
                />
              ) : <p className="text-sm text-slate-500">No IP data available.</p>}
            </div>
          </article>
        </section>

        <section className="chart-panel">
          <div className="mb-4 flex flex-wrap items-center justify-between gap-2">
            <h2 className="font-semibold">Recent Cowrie events</h2>
            <span className="text-xs text-slate-400">
              {events.length} displayed
            </span>
          </div>
          <div className="overflow-x-auto">
            <table className="w-full text-left">
              <thead>
                <tr>
                  {["Timestamp", "Source IP", "Event", "Input / Command", "Session"].map((x) => (
                    <th key={x} className="th-cell">{x}</th>
                  ))}
                </tr>
              </thead>
              <tbody>
                {events.map((event, i) => (
                  <tr key={`${event.session}-${event.timestamp}-${i}`} className="hover:bg-slate-800/60">
                    <td className="td-cell whitespace-nowrap text-slate-400">
                      {event.timestamp || "—"}
                    </td>
                    <td className="td-cell">{event.src_ip || "—"}</td>
                    <td className="td-cell">{event.eventid || "—"}</td>
                    <td className="td-cell max-w-xs break-words">
                      {event.input || event.command || "—"}
                    </td>
                    <td className="td-cell max-w-32 truncate text-slate-400">
                      {event.session || "—"}
                    </td>
                  </tr>
                ))}
              </tbody>
            </table>
            {!loading && events.length === 0 && (
              <p className="py-8 text-center text-slate-500">
                No events returned. Check the backend connection and table.
              </p>
            )}
          </div>
        </section>

        <section className="chart-panel">
          <h2 className="mb-4 font-semibold">Pipeline health</h2>
          <div className="grid gap-3 sm:grid-cols-2 lg:grid-cols-3">
            {[
              ["API", data.health?.backend],
              ["DynamoDB table", data.health?.table_reachable ? "reachable" : "unavailable"],
              ["Pipeline check", pipeline.status || pipeline.overall_status || pipeline.mode || "unknown"],
            ].map(([name, status]) => (
              <div key={name} className="rounded-lg bg-slate-800 p-4">
                <p className="text-sm text-slate-400">{name}</p>
                <p className="mt-2 break-words font-semibold">{status || "unknown"}</p>
              </div>
            ))}
          </div>
          <p className="mt-4 text-xs text-slate-500">
            Last refreshed: {updated || "not yet"} · Auto-refresh every 30 seconds
          </p>
        </section>
      </div>
    </main>
  );
}