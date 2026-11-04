import React, { useEffect, useRef } from "react";
import { X } from "lucide-react";

/**
 * 侧滑面板：宽屏贴右边、460px 宽；窄屏从底部升起，顶上留出顶栏的高度。
 * 打开时焦点移到关闭按钮并锁在面板内，Esc 或点遮罩关闭，关闭后焦点回到打开它的元素。
 *
 * @param {{
 *   open: boolean,
 *   title: React.ReactNode,
 *   hint?: React.ReactNode,
 *   icon?: React.ReactNode,
 *   label: string,
 *   onClose: () => void,
 *   children: React.ReactNode
 * }} props
 */
export function SidePanel({ open, title, hint, icon, label, onClose, children }) {
  const panelRef = useRef(null);
  const closeRef = useRef(null);
  const onCloseRef = useRef(onClose);
  onCloseRef.current = onClose;

  useEffect(() => {
    if (!open) return undefined;
    const previous = document.activeElement;
    closeRef.current?.focus();

    const onKeyDown = (event) => {
      if (event.key === "Escape") {
        event.stopPropagation();
        onCloseRef.current();
        return;
      }
      if (event.key !== "Tab") return;
      const focusables = panelRef.current?.querySelectorAll(
        'a[href], button:not([disabled]), summary, input, select, textarea, [tabindex]:not([tabindex="-1"])'
      );
      if (!focusables || focusables.length === 0) return;
      const first = focusables[0];
      const last = focusables[focusables.length - 1];
      if (event.shiftKey && document.activeElement === first) {
        event.preventDefault();
        last.focus();
      } else if (!event.shiftKey && document.activeElement === last) {
        event.preventDefault();
        first.focus();
      }
    };

    document.addEventListener("keydown", onKeyDown, true);
    return () => {
      document.removeEventListener("keydown", onKeyDown, true);
      if (previous instanceof HTMLElement && previous.isConnected) previous.focus();
    };
  }, [open]);

  if (!open) return null;

  return (
    <div className="fixed inset-0 z-50" role="presentation">
      <div
        className="absolute inset-0 bg-black/30"
        style={{ animation: "lens-fade-in 160ms var(--lens-ease) both" }}
        onMouseDown={() => onCloseRef.current()}
        aria-hidden
      />
      <aside
        ref={panelRef}
        role="dialog"
        aria-modal="true"
        aria-label={label}
        className="lens-panel absolute inset-x-0 bottom-0 top-14 flex flex-col rounded-t-2xl bg-surface-1 shadow-popover md:left-auto md:top-0 md:w-[460px] md:rounded-none"
      >
        <div className="flex shrink-0 items-start gap-3 px-[18px] pb-3.5 pt-[18px] shadow-[inset_0_-1px_0_var(--lens-line-soft)]">
          {icon}
          <div className="min-w-0 flex-1">
            <h2 className="truncate text-[18px] font-semibold tracking-[-0.01em] text-ink">{title}</h2>
            {hint ? <div className="text-[12.5px] text-ink-muted">{hint}</div> : null}
          </div>
          <button
            ref={closeRef}
            type="button"
            onClick={() => onCloseRef.current()}
            aria-label="关闭"
            className="inline-flex h-[30px] w-[30px] shrink-0 items-center justify-center rounded-lg text-ink-muted transition-colors duration-fast ease-lens hover:bg-[var(--lens-fill-hover)] hover:text-ink"
          >
            <X className="h-4 w-4" aria-hidden />
          </button>
        </div>
        <div className="flex min-h-0 flex-1 flex-col gap-3.5 overflow-y-auto px-[18px] pb-6 pt-4">{children}</div>
      </aside>
    </div>
  );
}
