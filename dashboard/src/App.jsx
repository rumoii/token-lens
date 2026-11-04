import React, { lazy, Suspense, useEffect, useState } from "react";
import { Navigate, useLocation } from "react-router-dom";
import { ErrorBoundary } from "./components/ErrorBoundary.jsx";
import { ThemeProvider } from "./ui/foundation/ThemeProvider.jsx";
import { AppLayout } from "./ui/components/Sidebar.jsx";
import { api } from "./lib/v1";
import { syncState } from "./lib/sync-state.js";
import { useResource } from "./pages/v1/shared.jsx";

const HomePage = lazy(() => import("./pages/v1/HomePage.jsx").then((m) => ({ default: m.HomePage })));
const OnboardingPage = lazy(() => import("./pages/v1/OnboardingPage.jsx").then((m) => ({ default: m.OnboardingPage })));
const SessionsPage = lazy(() => import("./pages/v1/SessionsPage.jsx").then((m) => ({ default: m.SessionsPage })));
const SourcesPage = lazy(() => import("./pages/v1/SourcesPage.jsx").then((m) => ({ default: m.SourcesPage })));
const SettingsPage = lazy(() => import("./pages/v1/SettingsPage.jsx").then((m) => ({ default: m.SettingsPage })));

const PAGES = {
  "/": HomePage,
  "/dashboard": HomePage,
  "/sessions": SessionsPage,
  "/sources": SourcesPage,
  "/settings": SettingsPage,
};

const ONBOARDED_KEY = "token-lens-onboarded";

function readOnboarded() {
  try {
    return typeof window !== "undefined" && window.localStorage?.getItem(ONBOARDED_KEY) === "1";
  } catch (_err) {
    return false;
  }
}

function markOnboarded() {
  try {
    window.localStorage?.setItem(ONBOARDED_KEY, "1");
  } catch (_err) {
    // localStorage 不可用就下次再问一次，不阻断使用
  }
}

export default function App() {
  // 首次引导门控：点过「去看看」后不再出现；请求失败按「有数据」处理
  const [gate, setGate] = useState(() => (readOnboarded() ? "app" : "loading"));
  useEffect(() => syncState.startMonitor(), []);
  const initial = useResource(() => api.summary(), [], { enabled: gate === "loading" });

  useEffect(() => {
    if (gate !== "loading") return undefined;
    if (initial.fresh) setGate(initial.data?.totals?.record_count === 0 ? "onboard" : "app");
    else if (initial.status === "error") setGate("app");
  }, [gate, initial.fresh, initial.status, initial.data]);

  const location = useLocation();
  const pathname = location.pathname.replace(/\/+$/, "") || "/";
  const Page = PAGES[pathname];

  if (gate === "loading") return null;

  if (gate === "onboard") {
    return (
      <ErrorBoundary>
        <ThemeProvider>
            <Suspense fallback={null}>
              <OnboardingPage
                onEnter={() => {
                  markOnboarded();
                  setGate("app");
                }}
              />
            </Suspense>
        </ThemeProvider>
      </ErrorBoundary>
    );
  }

  // 旧的用量页并进了首页的明细视图；旧书签照样能打开
  if (pathname === "/usage") return <Navigate to="/dashboard?view=detail" replace />;
  if (!Page) return <Navigate to="/dashboard" replace />;

  return (
    <ErrorBoundary>
      <ThemeProvider>
          <Suspense fallback={null}>
            <AppLayout>
              <Page />
            </AppLayout>
          </Suspense>
      </ThemeProvider>
    </ErrorBoundary>
  );
}
