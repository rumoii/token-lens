import { act, fireEvent, render, screen, waitFor, within } from '@testing-library/react';
import { MemoryRouter } from 'react-router-dom';
import { describe, expect, it, vi } from 'vitest';
import { AppLayout, getNavGroups } from './Sidebar';
import { ThemeProvider } from '../foundation/ThemeProvider';
import { api } from '../../lib/v1';
import { syncState } from '../../lib/sync-state';

function mount(path = '/dashboard?period=all&view=detail&tool=codex&model=old') {
  return render(<MemoryRouter initialEntries={[path]}><ThemeProvider><AppLayout><p>page content</p></AppLayout></ThemeProvider></MemoryRouter>);
}
function localData() {
  vi.spyOn(api, 'breakdown').mockResolvedValue({ totals: { gross_tokens: 200 }, groups: [{ key: 'codex', gross_tokens: 140 }, { key: 'claude', gross_tokens: 60 }, { key: null, gross_tokens: 99 }] });
  vi.spyOn(api, 'sources').mockResolvedValue({ sources: [{ source: 'gemini' }, { source: 'claude' }], last_run: null });
}

describe('navigation behavior', () => {
  it('shows all destinations, period-scoped links, sorted tools and zero-use sources without external probes', async () => {
    localData();
    const request = vi.fn();
    vi.stubGlobal('fetch', request);
    const start = vi.spyOn(syncState, 'startSync');
    mount();
    const tools = screen.getByRole('region', { name: '本期工具' });
    await within(tools).findByText('Codex');
    const links = within(tools).getAllByRole('link');
    expect(links.map(link => link.textContent)).toEqual(['Codex70%', 'Claude Code30%', 'Gemini CLI0%']);
    expect(new URL(links[1].href).searchParams.get('period')).toBe('all');
    expect(new URL(links[1].href).searchParams.get('tool')).toBe('claude');
    expect(new URL(links[1].href).searchParams.get('dim')).toBe('model');
    expect(new URL(links[1].href).searchParams.has('model')).toBe(false);
    expect(links[0]).toHaveAttribute('aria-current', 'page');
    expect(getNavGroups().map(item => item.to)).toEqual(['/dashboard', '/dashboard?view=detail', '/sessions', '/sources', '/settings']);
    expect(screen.getByRole('link', { name: '用量明细' })).toHaveAttribute('aria-current', 'page');
    expect(screen.getByRole('link', { name: '用量总览' })).not.toHaveAttribute('aria-current');
    expect(request).toHaveBeenCalledTimes(0);
    expect(start).toHaveBeenCalledTimes(0);
  });
  it('keeps focus inside the drawer and returns it after Escape, overlay and navigation', async () => {
    localData();
    mount('/settings');
    const trigger = screen.getByRole('button', { name: '打开导航菜单' });
    fireEvent.click(trigger);
    let dialog = await screen.findByRole('dialog', { name: '导航菜单' });
    const controls = [...dialog.querySelectorAll('a[href],button:not(:disabled)')];
    expect(controls[0]).toHaveFocus();
    fireEvent.keyDown(controls[0], { key: 'Tab', shiftKey: true });
    expect(controls.at(-1)).toHaveFocus();
    fireEvent.keyDown(controls.at(-1), { key: 'Tab' });
    expect(controls[0]).toHaveFocus();
    fireEvent.keyDown(dialog, { key: 'Escape' });
    expect(trigger).toHaveFocus();
    expect(trigger).toHaveAttribute('aria-expanded', 'false');
    fireEvent.click(trigger);
    fireEvent.click(screen.getByRole('button', { name: '关闭导航遮罩' }));
    expect(trigger).toHaveFocus();
    fireEvent.click(trigger);
    dialog = screen.getByRole('dialog');
    fireEvent.click(within(dialog).getByRole('link', { name: '价格与设置' }));
    expect(trigger).toHaveAttribute('aria-expanded', 'false');
    fireEvent.click(trigger);
    dialog = screen.getByRole('dialog');
    fireEvent.click(within(dialog).getByRole('link', { name: '用量总览' }));
    await waitFor(() => expect(trigger).toHaveAttribute('aria-expanded', 'false'));
    expect(screen.getByRole('main')).toHaveTextContent('page content');
  });
  it('retries failed local reads without starting a collection and omits an empty tools section', async () => {
    vi.spyOn(api, 'breakdown').mockRejectedValueOnce(new Error('local read failed')).mockResolvedValue({ groups: [], totals: { gross_tokens: 0 } });
    const sources = vi.spyOn(api, 'sources').mockResolvedValue({ sources: [] });
    const start = vi.spyOn(syncState, 'startSync');
    mount();
    await screen.findByRole('alert');
    fireEvent.click(screen.getByText('重试读取'));
    await waitFor(() => expect(screen.queryByRole('alert')).toBeNull());
    expect(sources).toHaveBeenCalledTimes(2);
    expect(start).toHaveBeenCalledTimes(0);
    expect(screen.queryByRole('heading', { name: '本期工具' })).toBeNull();
  });
});
