import { ApiError, api, invalidateReadRequests, request } from "./v1";

// 来源检查会扫描账本及日志路径，空闲观察跟随五分钟采集周期。
export const SYNC_IDLE_MS = 300000;
export const SYNC_POLL_MS = 2000;
export const SYNC_WAIT_MS = 120000;
export const SYNC_REQUEST_MS = 10000;

function fingerprint(run) {
  return JSON.stringify(run ? [run.started_at, run.finished_at, run.status, run.attempted,
    run.inserted, run.updated, run.unchanged, run.rejected, run.counts, run.anomalies] : null);
}

export function isSuccessfulRun(run) {
  return run?.status === "ok" || run?.status === "completed_with_anomalies";
}

function matchesResult(run, receipt) {
  if (!receipt || !isSuccessfulRun(run)) return false;
  const { result, startedAt, finishedAt } = receipt;
  const completedAt = Date.parse(run.finished_at);
  // 内核与页面共用本机时钟；账本完成时间只有秒精度。
  if (!(completedAt >= Math.floor(startedAt / 1000) * 1000 && completedAt <= finishedAt)) return false;
  const fields = ["attempted", "inserted", "updated", "unchanged", "rejected"];
  const supplied = fields.filter(key => result[key] !== undefined);
  if (!supplied.length || supplied.some(key => result[key] !== run[key])) return false;
  if (result.counts && (!run.counts || Object.keys(result.counts).some(key => result.counts[key] !== run.counts[key]))) return false;
  return !result.anomalies || (result.anomalies.length === run.anomaly_count
    && JSON.stringify(result.anomalies.slice(0, 5)) === JSON.stringify(run.anomalies));
}

export function createSyncState() {
  let state = { version: 0, phase: "idle", result: null, warning: null, error: null, errorKind: null, lastRun: null, origin: null };
  const listeners = new Set();
  let pending = null;
  let operation = 0;
  let owners = 0;
  let timer = null;
  let controller = null;
  let requestTimer = null;
  let observation = 0;
  let seen = null;
  let waitingSince = null;
  let sawRunning = false;
  let paused = false;
  // POST 已失效过的结果，保留到实际读到终态；隐藏或卸载不能丢掉这份回执。
  let unconfirmedResult = null;

  const publish = patch => {
    state = { ...state, ...patch };
    listeners.forEach(listener => listener());
  };
  const invalidate = patch => {
    invalidateReadRequests();
    publish({ ...patch, version: state.version + 1 });
  };
  const clearTimer = () => { clearTimeout(timer); timer = null; };
  const stopRead = () => {
    observation++;
    clearTimeout(requestTimer);
    requestTimer = null;
    controller?.abort();
    controller = null;
  };
  const schedule = () => {
    clearTimer();
    if (!owners || document.visibilityState === "hidden" || pending || paused) return;
    const delay = waitingSince === null ? SYNC_IDLE_MS : Math.min(SYNC_POLL_MS, Math.max(0, SYNC_WAIT_MS - (Date.now() - waitingSince)));
    timer = setTimeout(() => { timer = null; check(); }, delay);
  };

  async function check() {
    if (!owners || controller || pending || document.visibilityState === "hidden") return;
    clearTimer();
    const ticket = ++observation;
    const abort = new AbortController();
    controller = abort;
    let expired = false;
    try {
      const timeout = new Promise((_, reject) => {
        const remaining = waitingSince === null ? SYNC_REQUEST_MS : Math.max(0, SYNC_WAIT_MS - (Date.now() - waitingSince));
        requestTimer = setTimeout(() => {
          expired = true;
          abort.abort();
          reject(new Error("请求超时"));
        }, Math.min(SYNC_REQUEST_MS, remaining));
      });
      const response = await Promise.race([request("/sources", { signal: abort.signal }), timeout]);
      if (ticket !== observation) return;
      paused = false;
      const run = response?.last_run ?? null;
      const next = fingerprint(run);
      if (run?.status === "running") {
        unconfirmedResult = null;
        sawRunning = true;
        waitingSince ??= Date.now();
        if (Date.now() - waitingSince >= SYNC_WAIT_MS) {
          paused = true;
          publish({ phase: "timed_out", error: new Error("等待超时，同步可能仍在进行"), errorKind: "sync", lastRun: run });
        } else publish({ lastRun: run, phase: state.phase === "conflict" ? "conflict" : "running", origin: state.origin ?? "observed" });
        seen = next;
      } else if (run && (isSuccessfulRun(run) || ["failed", "abandoned"].includes(run.status) || run.finished_at)) {
        const changed = seen !== null && seen !== next;
        const ownCompletion = matchesResult(run, unconfirmedResult);
        const complete = unconfirmedResult !== null || changed || sawRunning || (waitingSince !== null && seen === null);
        // 有基线且仍是原终态时继续等；无基线的首个终态则保守失效，不能永远等不到变化。
        if (waitingSince !== null && !complete) {
          if (Date.now() - waitingSince >= SYNC_WAIT_MS) {
            paused = true;
            publish({ phase: "timed_out", error: new Error("等待超时，同步可能仍在进行"), errorKind: "sync" });
          }
        } else {
          const patch = { lastRun: run };
          const success = isSuccessfulRun(run);
          if (complete || state.origin === null) Object.assign(patch, {
            phase: success ? "success" : "error",
            warning: success ? run.anomalies?.join("；") || null : null,
            error: success ? null : new Error(run.anomalies?.[0] || (["failed", "abandoned"].includes(run.status)
              ? "上次同步没有完成" : `无法识别同步终态：${run.status}`)),
            errorKind: success ? null : "sync",
            result: ownCompletion ? state.result : null,
            origin: ownCompletion ? "manual" : "observed"
          });
          if (complete && !ownCompletion) invalidate(patch);
          else publish(patch);
          unconfirmedResult = null;
          waitingSince = null;
          sawRunning = false;
        }
        seen = next;
      } else if (!run && waitingSince === null) {
        seen = next;
        publish({ lastRun: null });
      } else throw new Error("无法确认同步状态");
    } catch (error) {
      if (ticket !== observation) return;
      paused = true;
      const waitExpired = waitingSince !== null && Date.now() - waitingSince >= SYNC_WAIT_MS;
      publish({ phase: waitExpired ? "timed_out" : "error", error: new Error(waitExpired
        ? "等待超时，同步可能仍在进行" : `无法确认同步状态：${expired ? "请求超时" : error.message}`), errorKind: waitExpired ? "sync" : "status" });
    } finally {
      if (ticket === observation) {
        clearTimeout(requestTimer);
        requestTimer = null;
        controller = null;
        schedule();
      }
    }
  }

  function startSync() {
    if (pending) return pending;
    if (waitingSince !== null && ["running", "conflict"].includes(state.phase)) {
      return Promise.reject(new ApiError(409, "sync_in_progress", "已有同步在执行"));
    }
    clearTimer();
    stopRead();
    const ticket = ++operation;
    const startedAt = Date.now();
    paused = false;
    unconfirmedResult = null;
    waitingSince = null;
    sawRunning = false;
    publish({ phase: "running", error: null, errorKind: null, result: null, warning: null, origin: "manual" });
    const work = Promise.resolve().then(() => api.sync()).then(result => {
      if (ticket === operation) {
        waitingSince = null;
        unconfirmedResult = { result, startedAt, finishedAt: Date.now() };
        invalidate({ phase: "success", result, warning: result.anomalies?.join("；") || null, error: null, errorKind: null });
      }
      return result;
    }, error => {
      if (ticket === operation) {
        if (error instanceof ApiError && error.status === 409 && error.code === "sync_in_progress") {
          waitingSince = Date.now();
          sawRunning = false;
          publish({ phase: "conflict", error, errorKind: null });
        } else {
          waitingSince = null;
          invalidate({ phase: "error", error, errorKind: "sync" });
        }
      }
      throw error;
    }).finally(() => {
      if (ticket !== operation) return;
      pending = null;
      if (state.phase === "success") check();
      else if (state.phase === "conflict") check();
      else schedule();
    });
    pending = work;
    return work;
  }

  function retryStatus() {
    stopRead();
    paused = false;
    if (waitingSince !== null) waitingSince = Date.now();
    publish({ phase: waitingSince === null ? "idle" : "conflict", error: null, errorKind: null });
    return check();
  }

  function onVisibility() {
    clearTimer();
    if (document.visibilityState === "hidden") stopRead();
    else if (!pending) check();
  }

  function startMonitor() {
    owners++;
    if (owners === 1) {
      paused = false;
      document.addEventListener("visibilitychange", onVisibility);
      window.addEventListener("focus", onVisibility);
      check();
    }
    let disposed = false;
    return () => {
      if (disposed) return;
      disposed = true;
      if (--owners) return;
      clearTimer();
      stopRead();
      document.removeEventListener("visibilitychange", onVisibility);
      window.removeEventListener("focus", onVisibility);
      // 只释放观察资源。POST 属于窗口 store，仍可在重新挂载后复用并接收结果。
    };
  }

  return { getSnapshot: () => state, subscribe: listener => {
    listeners.add(listener);
    return () => listeners.delete(listener);
  }, startSync, retryStatus, startMonitor };
}

export const syncState = createSyncState();
