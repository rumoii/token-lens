import React, { useContext } from "react";
import { fireEvent, render, screen } from "@testing-library/react";
import { describe, expect, it, vi } from "vitest";
import { Nt, TweenNt } from "./HomeParts.jsx";
import { LocaleProvider } from "../../ui/foundation/LocaleProvider.jsx";
import { TokenFormatContext, TokenFormatProvider } from "../../ui/foundation/TokenFormatProvider.jsx";

vi.mock("../../lib/use-tween", () => ({ useTween: (value) => value }));

function Units({ value }) {
  const { setUnitSystem } = useContext(TokenFormatContext);
  return <><Nt value={value} /><TweenNt value={value} />
    <button onClick={() => setUnitSystem("chinese")}>中文单位</button></>;
}

describe("主要数字单位", () => {
  it.each([[1200, "1.2K", "1,200"], [1200000, "1.2M", "120万"], [1200000000, "1.2B", "12亿"]])(
    "Nt 和 TweenNt 按 Provider 设置格式化 %s", (value, english, chinese) => {
      localStorage.setItem("tt.tokenUnitSystem", "english");
      render(<LocaleProvider><TokenFormatProvider><Units value={value} /></TokenFormatProvider></LocaleProvider>);
      const numbers = screen.getAllByTitle(`${value.toLocaleString("en-US")} token`);
      expect(numbers.map((node) => node.textContent)).toEqual([english, english]);
      fireEvent.click(screen.getByRole("button", { name: "中文单位" }));
      expect(numbers.map((node) => node.textContent)).toEqual([chinese, chinese]);
    }
  );
});
