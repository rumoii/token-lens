import React, { useEffect, useRef } from "react";
import { X } from "lucide-react";

/**
 * 弹窗。按 CDS 的对话框规格：16px 圆角、最大宽 448px、双环阴影、
 * 遮罩带模糊、Esc 与点遮罩关闭、焦点锁在弹窗内。
 *
 * @param {{
 *   open: boolean,
 *   title: string,
 *   hint?: string,
 *   onClose: () => void,
 *   children: React.ReactNode,
 *   footer?: React.ReactNode
 * }} props
 */
export function Modal({ open, title, hint, onClose, children, footer }) {
  const panelRef = useRef(null);

  useEffect(() => {
    if (!open) return undefined;

    const previous = document.activeElement;
    const previousOverflow = document.body.style.overflow;
    document.body.style.overflow = "hidden";
    panelRef.current?.focus();

    const onKeyDown = (event) => {
      if (event.key === "Escape") {
        event.stopPropagation();
        onClose();
        return;
      }
      if (event.key !== "Tab") return;

      // 焦点循环：不让 Tab 跑出弹窗
      const focusables = panelRef.current?.querySelectorAll(
        'a[href], button:not([disabled]), input, select, textarea, [tabindex]:not([tabindex="-1"])'
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
      document.body.style.overflow = previousOverflow;
      if (previous instanceof HTMLElement) previous.focus();
    };
  }, [open, onClose]);

  if (!open) return null;

  return (
    <div
      className="fixed inset-0 z-50 flex items-center justify-center p-4"
      role="presentation"
      onMouseDown={(event) => {
        if (event.target === event.currentTarget) onClose();
      }}
    >
      <div
        className="absolute inset-0 bg-black/30 backdrop-blur-[2px]"
        style={{ animation: "lens-fade-in 160ms var(--lens-ease) both" }}
        aria-hidden
      />
      <div
        ref={panelRef}
        role="dialog"
        aria-modal="true"
        aria-label={title}
        tabIndex={-1}
        className="relative flex max-h-[85vh] w-full max-w-[448px] flex-col rounded-2xl bg-surface-2 p-5 shadow-popover outline-none"
        style={{ animation: "lens-dialog-in 200ms cubic-bezier(.165,.84,.44,1) both" }}
      >
        <div className="flex shrink-0 items-start justify-between gap-3">
          <div className="min-w-0">
            <h2 className="text-lede font-semibold tracking-tight text-ink">{title}</h2>
            {hint ? <p className="mt-0.5 text-caption text-ink-muted">{hint}</p> : null}
          </div>
          <button
            type="button"
            onClick={onClose}
            aria-label="关闭"
            className="-mr-1 -mt-1 inline-flex h-7 w-7 shrink-0 items-center justify-center rounded-md text-ink-muted transition-colors duration-fast ease-lens hover:bg-[var(--lens-fill-hover)] hover:text-ink"
          >
            <X className="h-4 w-4" aria-hidden />
          </button>
        </div>

        <div className="mt-4 min-h-0 flex-1 overflow-y-auto">{children}</div>
        {footer ? <div className="mt-4 flex shrink-0 justify-end gap-2">{footer}</div> : null}
      </div>
    </div>
  );
}
