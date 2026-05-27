/**
 * CodeBench vim-lite mode for Monaco
 * ───────────────────────────────────
 * A compact (no-deps) vim emulation covering the ~80% most-used
 * commands. Trade-offs vs the full monaco-vim package:
 *
 *   Supported:
 *     • Modes:   NORMAL, INSERT, VISUAL (char), VISUAL LINE
 *     • Motion:  h j k l   w b e   0 $ ^   gg G   { }   % (bracket)
 *     • Insert:  i a I A o O
 *     • Edit:    x X r   dd yy cc   d{motion} y{motion} c{motion}
 *                p P   u <C-r>   J   .  (last-change repeat)
 *     • Search:  / ? n N   * #
 *     • Visual:  v V  (then d / y / c / x)
 *     • Cmdline: :w :q :wq :x  (saves via postToSwift / no-ops :q)
 *     • Counts:  3dd, 5j, 10G, etc.
 *
 *   Not (yet) supported: macros, marks, registers (only unnamed),
 *     ex-commands beyond save/quit, ci"/da( text-objects, folds.
 *
 * To enable the FULL monaco-vim package later, drop monaco-vim.min.js
 * into Resources/Monaco/ and replace `enableVimLite(editor)` with
 * `MonacoVim.initVimMode(editor, statusEl)`. The toggle plumbing in
 * editor.html doesn't care which impl is wired up underneath.
 *
 * Persistence: the on/off flag lives in localStorage under
 * `codebench.vim.enabled` so it survives editor reloads.
 */

(function () {
    'use strict';

    // ─────────────────────────────────────────────────────────────
    // State
    // ─────────────────────────────────────────────────────────────
    const MODE = { NORMAL: 'NORMAL', INSERT: 'INSERT', VISUAL: 'VISUAL', VLINE: 'V-LINE' };

    let _editor = null;
    let _statusEl = null;
    let _mode = MODE.NORMAL;
    let _pending = '';          // pending command keys (e.g. "2d" waiting for "d")
    let _countBuf = '';         // numeric prefix ("23g" → count=23, then "g")
    let _yankBuf = { text: '', linewise: false };
    let _lastChange = null;     // for `.` repeat: { op, args }
    let _visualAnchor = null;   // position where visual mode started
    let _searchTerm = '';
    let _searchDir = 1;         // 1=forward, -1=backward
    let _cmdline = '';          // text after ":" in command-line mode
    let _inCmdline = false;
    let _disposables = [];      // Monaco listeners to remove on disable
    let _keydownHandler = null; // top-level keydown listener
    let _enabled = false;

    // ─────────────────────────────────────────────────────────────
    // Status bar
    // ─────────────────────────────────────────────────────────────
    function updateStatus(msg) {
        if (!_statusEl) return;
        const modeColors = {
            NORMAL: '#6366f1', INSERT: '#34d399',
            VISUAL: '#a855f7', 'V-LINE': '#a855f7'
        };
        _statusEl.style.background = modeColors[_mode] || '#6b6b80';
        const extra = msg ? ' · ' + msg : (_pending ? ' · ' + _pending : '');
        _statusEl.textContent = _mode + extra;
    }

    // ─────────────────────────────────────────────────────────────
    // Cursor / position helpers
    // ─────────────────────────────────────────────────────────────
    function pos() {
        const p = _editor.getPosition();
        return { ln: p.lineNumber, col: p.column };
    }
    function setPos(ln, col) {
        const model = _editor.getModel();
        if (!model) return;
        ln = Math.max(1, Math.min(ln, model.getLineCount()));
        const maxCol = model.getLineMaxColumn(ln);
        col = Math.max(1, Math.min(col, maxCol));
        _editor.setPosition({ lineNumber: ln, column: col });
        _editor.revealPositionInCenterIfOutsideViewport({ lineNumber: ln, column: col });
        if (_mode === MODE.VISUAL || _mode === MODE.VLINE) {
            refreshVisualSelection();
        }
    }
    function lineText(ln) {
        const m = _editor.getModel();
        return m ? m.getLineContent(ln) : '';
    }
    function lineCount() {
        const m = _editor.getModel();
        return m ? m.getLineCount() : 1;
    }

    // ─────────────────────────────────────────────────────────────
    // Mode switching
    // ─────────────────────────────────────────────────────────────
    function setMode(m, opts) {
        opts = opts || {};
        _mode = m;
        _pending = '';
        if (m === MODE.NORMAL) {
            // Restore block-cursor appearance
            _editor.updateOptions({ cursorStyle: 'block', cursorBlinking: 'solid' });
            _visualAnchor = null;
            // Snap cursor off the trailing newline column (vim normal
            // mode never sits past the last char of a line).
            const p = pos();
            const lineEnd = _editor.getModel().getLineMaxColumn(p.ln);
            if (p.col === lineEnd && lineEnd > 1) setPos(p.ln, lineEnd - 1);
        } else if (m === MODE.INSERT) {
            _editor.updateOptions({ cursorStyle: 'line', cursorBlinking: 'blink' });
        } else if (m === MODE.VISUAL || m === MODE.VLINE) {
            _editor.updateOptions({ cursorStyle: 'block', cursorBlinking: 'solid' });
            _visualAnchor = pos();
            refreshVisualSelection();
        }
        updateStatus();
    }

    function refreshVisualSelection() {
        if (!_visualAnchor) return;
        const p = pos();
        let sel;
        if (_mode === MODE.VLINE) {
            const a = Math.min(_visualAnchor.ln, p.ln);
            const b = Math.max(_visualAnchor.ln, p.ln);
            const lastCol = _editor.getModel().getLineMaxColumn(b);
            sel = new monaco.Selection(a, 1, b, lastCol);
        } else {
            const forward = (p.ln > _visualAnchor.ln) ||
                            (p.ln === _visualAnchor.ln && p.col >= _visualAnchor.col);
            sel = forward
                ? new monaco.Selection(_visualAnchor.ln, _visualAnchor.col, p.ln, p.col + 1)
                : new monaco.Selection(_visualAnchor.ln, _visualAnchor.col + 1, p.ln, p.col);
        }
        _editor.setSelection(sel);
    }

    // ─────────────────────────────────────────────────────────────
    // Word boundaries (used by w/b/e)
    // ─────────────────────────────────────────────────────────────
    function isWordChar(c) { return /\w/.test(c); }
    function isSpace(c)    { return /\s/.test(c); }

    function wordForward() {
        const p = pos();
        const ln = p.ln, ln_text = lineText(ln);
        let col = p.col;
        // Skip current word chars
        while (col <= ln_text.length && isWordChar(ln_text[col - 1])) col++;
        // Skip whitespace
        while (col <= ln_text.length && isSpace(ln_text[col - 1])) col++;
        if (col > ln_text.length) {
            // Wrap to next line if available
            if (ln < lineCount()) setPos(ln + 1, 1);
        } else setPos(ln, col);
    }

    function wordBackward() {
        const p = pos();
        let ln = p.ln, col = p.col - 1;
        let txt = lineText(ln);
        while (col >= 1 && isSpace(txt[col - 1])) col--;
        if (col < 1) {
            if (ln > 1) {
                ln--; txt = lineText(ln);
                col = txt.length;
            } else { return; }
        }
        // Walk left while still on word char
        while (col > 1 && isWordChar(txt[col - 2])) col--;
        setPos(ln, col);
    }

    // ─────────────────────────────────────────────────────────────
    // Edits (delete-line, yank-line, paste, etc.)
    // ─────────────────────────────────────────────────────────────
    function deleteCurrentLine(count) {
        count = count || 1;
        const p = pos();
        const lc = lineCount();
        const startLn = p.ln;
        const endLn = Math.min(startLn + count - 1, lc);
        const model = _editor.getModel();
        // Yank first
        const text = [];
        for (let i = startLn; i <= endLn; i++) text.push(lineText(i));
        _yankBuf = { text: text.join('\n') + '\n', linewise: true };
        // Delete
        let range;
        if (endLn === lc) {
            // Last line — include previous line's trailing newline
            const prev = Math.max(startLn - 1, 1);
            range = new monaco.Range(prev, model.getLineMaxColumn(prev),
                                     endLn, model.getLineMaxColumn(endLn));
        } else {
            range = new monaco.Range(startLn, 1, endLn + 1, 1);
        }
        _editor.executeEdits('vim-dd', [{ range: range, text: '', forceMoveMarkers: true }]);
        // Cursor goes to first non-blank of new current line
        const newLn = Math.min(startLn, lineCount());
        moveToFirstNonBlank(newLn);
    }

    function yankCurrentLine(count) {
        count = count || 1;
        const p = pos();
        const text = [];
        for (let i = 0; i < count && p.ln + i <= lineCount(); i++) {
            text.push(lineText(p.ln + i));
        }
        _yankBuf = { text: text.join('\n') + '\n', linewise: true };
    }

    function paste(before) {
        if (!_yankBuf.text) return;
        const p = pos();
        const model = _editor.getModel();
        if (_yankBuf.linewise) {
            // Insert as new line(s) after current line (before = above)
            const targetLn = before ? p.ln : p.ln + 1;
            const range = (targetLn > lineCount())
                ? new monaco.Range(lineCount(), model.getLineMaxColumn(lineCount()),
                                   lineCount(), model.getLineMaxColumn(lineCount()))
                : new monaco.Range(targetLn, 1, targetLn, 1);
            const text = (targetLn > lineCount())
                ? '\n' + _yankBuf.text.replace(/\n$/, '')
                : _yankBuf.text;
            _editor.executeEdits('vim-p', [{ range: range, text: text, forceMoveMarkers: true }]);
            moveToFirstNonBlank(targetLn);
        } else {
            const col = before ? p.col : p.col + 1;
            const range = new monaco.Range(p.ln, col, p.ln, col);
            _editor.executeEdits('vim-p', [{ range: range, text: _yankBuf.text,
                                            forceMoveMarkers: true }]);
        }
    }

    function moveToFirstNonBlank(ln) {
        const txt = lineText(ln);
        let col = 1;
        while (col <= txt.length && isSpace(txt[col - 1])) col++;
        setPos(ln, col);
    }

    // Visual-mode op: apply yank/delete/change to current selection
    function visualOp(op) {
        const sel = _editor.getSelection();
        if (!sel) return;
        const text = _editor.getModel().getValueInRange(sel);
        _yankBuf = { text: text, linewise: _mode === MODE.VLINE };
        if (op === 'y') {
            _editor.setPosition({ lineNumber: sel.startLineNumber, column: sel.startColumn });
            setMode(MODE.NORMAL);
        } else if (op === 'd' || op === 'c' || op === 'x') {
            _editor.executeEdits('vim-vop', [{ range: sel, text: '', forceMoveMarkers: true }]);
            setMode(op === 'c' ? MODE.INSERT : MODE.NORMAL);
        }
    }

    // ─────────────────────────────────────────────────────────────
    // Search
    // ─────────────────────────────────────────────────────────────
    function findNext(term, dir) {
        if (!term) return;
        const model = _editor.getModel();
        if (!model) return;
        const p = pos();
        const matches = model.findMatches(term, true, false, false, null, false);
        if (matches.length === 0) { updateStatus("no match: " + term); return; }
        // Find next match after cursor
        let target = null;
        if (dir > 0) {
            target = matches.find(m => m.range.startLineNumber > p.ln ||
                (m.range.startLineNumber === p.ln && m.range.startColumn > p.col)) || matches[0];
        } else {
            const rev = matches.slice().reverse();
            target = rev.find(m => m.range.startLineNumber < p.ln ||
                (m.range.startLineNumber === p.ln && m.range.startColumn < p.col)) || matches[matches.length - 1];
        }
        setPos(target.range.startLineNumber, target.range.startColumn);
    }

    // ─────────────────────────────────────────────────────────────
    // Command-line mode (:w, :q, :wq, :x)
    // ─────────────────────────────────────────────────────────────
    function execCmdline(cmd) {
        cmd = cmd.trim();
        if (cmd === 'w' || cmd === 'wq' || cmd === 'x') {
            // Tell Swift to save the current file.
            if (typeof window.postToSwift === 'function') {
                window.postToSwift({ kind: 'vimSave' });
            }
            updateStatus('saved');
        }
        if (cmd === 'q' || cmd === 'wq' || cmd === 'x') {
            // No-op — there's no concept of closing a file from inside the editor.
            updateStatus('(quit is no-op)');
        }
        _inCmdline = false;
        _cmdline = '';
    }

    // ─────────────────────────────────────────────────────────────
    // Key dispatcher (NORMAL mode is the meaty one)
    // ─────────────────────────────────────────────────────────────
    function handleNormalKey(key, e) {
        // Cmdline mode (after ":")
        if (_inCmdline) {
            if (key === 'Enter') {
                execCmdline(_cmdline);
                updateStatus();
                return true;
            }
            if (key === 'Escape') { _inCmdline = false; _cmdline = ''; updateStatus(); return true; }
            if (key === 'Backspace') { _cmdline = _cmdline.slice(0, -1); updateStatus(':' + _cmdline); return true; }
            if (key.length === 1) { _cmdline += key; updateStatus(':' + _cmdline); return true; }
            return false;
        }

        // Numeric count prefix
        if (/^[0-9]$/.test(key) && !(key === '0' && _countBuf === '')) {
            _countBuf += key;
            updateStatus(_countBuf + _pending);
            return true;
        }
        const count = _countBuf ? parseInt(_countBuf, 10) : 1;

        // Pending two-char ops (dd, yy, cc, gg)
        if (_pending) {
            const combo = _pending + key;
            _pending = '';
            updateStatus();
            switch (combo) {
                case 'dd': deleteCurrentLine(count); _lastChange = { op: 'dd', count: count }; _countBuf = ''; return true;
                case 'yy': yankCurrentLine(count); _countBuf = ''; return true;
                case 'cc': deleteCurrentLine(count); setMode(MODE.INSERT); _lastChange = { op: 'cc', count: count }; _countBuf = ''; return true;
                case 'gg': setPos(count > 1 ? count : 1, 1); _countBuf = ''; return true;
                case 'dw': { _pending = ''; const start = pos(); wordForward(); const end = pos();
                    const r = new monaco.Range(start.ln, start.col, end.ln, end.col);
                    _yankBuf = { text: _editor.getModel().getValueInRange(r), linewise: false };
                    _editor.executeEdits('vim-dw', [{ range: r, text: '', forceMoveMarkers: true }]);
                    setPos(start.ln, start.col); _countBuf = ''; return true; }
                case 'cw': { const start = pos(); wordForward(); const end = pos();
                    const r = new monaco.Range(start.ln, start.col, end.ln, end.col);
                    _yankBuf = { text: _editor.getModel().getValueInRange(r), linewise: false };
                    _editor.executeEdits('vim-cw', [{ range: r, text: '', forceMoveMarkers: true }]);
                    setPos(start.ln, start.col); setMode(MODE.INSERT); _countBuf = ''; return true; }
            }
            _countBuf = '';
            return true;
        }

        // Single-key commands
        switch (key) {
            // Movement
            case 'h': { const p = pos(); setPos(p.ln, Math.max(1, p.col - count)); break; }
            case 'l': { const p = pos(); setPos(p.ln, p.col + count); break; }
            case 'j': { const p = pos(); setPos(p.ln + count, p.col); break; }
            case 'k': { const p = pos(); setPos(p.ln - count, p.col); break; }
            case 'w': for (let i = 0; i < count; i++) wordForward(); break;
            case 'b': for (let i = 0; i < count; i++) wordBackward(); break;
            case '0': { const p = pos(); setPos(p.ln, 1); break; }
            case '$': { const p = pos(); setPos(p.ln, _editor.getModel().getLineMaxColumn(p.ln) - 1); break; }
            case '^': moveToFirstNonBlank(pos().ln); break;
            case 'G': setPos(_countBuf ? count : lineCount(), 1); break;
            case 'g': _pending = 'g'; updateStatus('g'); _countBuf = ''; return true;
            // Mode switches
            case 'i': setMode(MODE.INSERT); break;
            case 'a': { const p = pos(); setPos(p.ln, p.col + 1); setMode(MODE.INSERT); break; }
            case 'I': moveToFirstNonBlank(pos().ln); setMode(MODE.INSERT); break;
            case 'A': { const p = pos(); setPos(p.ln, _editor.getModel().getLineMaxColumn(p.ln)); setMode(MODE.INSERT); break; }
            case 'o': { const p = pos();
                const ec = _editor.getModel().getLineMaxColumn(p.ln);
                _editor.executeEdits('vim-o', [{ range: new monaco.Range(p.ln, ec, p.ln, ec), text: '\n', forceMoveMarkers: true }]);
                setPos(p.ln + 1, 1); setMode(MODE.INSERT); break; }
            case 'O': { const p = pos();
                _editor.executeEdits('vim-O', [{ range: new monaco.Range(p.ln, 1, p.ln, 1), text: '\n', forceMoveMarkers: true }]);
                setPos(p.ln, 1); setMode(MODE.INSERT); break; }
            case 'v': setMode(MODE.VISUAL); break;
            case 'V': setMode(MODE.VLINE); break;
            // Edits
            case 'x': { const p = pos(); const r = new monaco.Range(p.ln, p.col, p.ln, p.col + count);
                _yankBuf = { text: _editor.getModel().getValueInRange(r), linewise: false };
                _editor.executeEdits('vim-x', [{ range: r, text: '', forceMoveMarkers: true }]); break; }
            case 'X': { const p = pos(); if (p.col === 1) break;
                const r = new monaco.Range(p.ln, p.col - count, p.ln, p.col);
                _yankBuf = { text: _editor.getModel().getValueInRange(r), linewise: false };
                _editor.executeEdits('vim-X', [{ range: r, text: '', forceMoveMarkers: true }]); break; }
            case 'd': _pending = 'd'; updateStatus('d'); _countBuf = ''; return true;
            case 'y': _pending = 'y'; updateStatus('y'); _countBuf = ''; return true;
            case 'c': _pending = 'c'; updateStatus('c'); _countBuf = ''; return true;
            case 'p': for (let i = 0; i < count; i++) paste(false); _lastChange = { op: 'p', count: count }; break;
            case 'P': for (let i = 0; i < count; i++) paste(true); break;
            case 'u': for (let i = 0; i < count; i++) _editor.trigger('vim', 'undo', {}); break;
            // Search
            case '/': _searchDir = 1; _inCmdline = true; _cmdline = ''; updateStatus('/'); return true;
            case '?': _searchDir = -1; _inCmdline = true; _cmdline = ''; updateStatus('?'); return true;
            case 'n': findNext(_searchTerm, _searchDir); break;
            case 'N': findNext(_searchTerm, -_searchDir); break;
            // Cmdline
            case ':': _inCmdline = true; _cmdline = ''; updateStatus(':'); return true;
            // Join
            case 'J': { const p = pos(); const m = _editor.getModel();
                if (p.ln >= m.getLineCount()) break;
                const endThis = m.getLineMaxColumn(p.ln);
                const startNext = lineText(p.ln + 1).search(/\S/);
                const r = new monaco.Range(p.ln, endThis, p.ln + 1, (startNext < 0 ? 0 : startNext) + 1);
                _editor.executeEdits('vim-J', [{ range: r, text: ' ', forceMoveMarkers: true }]); break; }
            // Repeat
            case '.': if (_lastChange && _lastChange.op === 'dd') deleteCurrentLine(_lastChange.count); break;
            // Ctrl chords
            default:
                if (e.ctrlKey && key === 'r') {
                    _editor.trigger('vim', 'redo', {});
                } else {
                    _countBuf = '';
                    return false;
                }
        }
        _countBuf = '';
        return true;
    }

    function handleVisualKey(key, e) {
        // Cmdline support inside visual
        if (key === 'Escape') { setMode(MODE.NORMAL); return true; }
        if (key === 'd' || key === 'x') { visualOp('d'); return true; }
        if (key === 'y') { visualOp('y'); return true; }
        if (key === 'c') { visualOp('c'); return true; }
        // Movement reuses normal-mode handler
        return handleNormalKey(key, e);
    }

    function handleInsertKey(key) {
        if (key === 'Escape') {
            setMode(MODE.NORMAL);
            return true;
        }
        return false;
    }

    // ─────────────────────────────────────────────────────────────
    // Top-level keydown
    // ─────────────────────────────────────────────────────────────
    function onKeyDown(e) {
        if (!_enabled) return;
        // Ignore IME composition events
        if (e.isComposing) return;

        // Mac Ctrl-[ → Escape mapping (common vim convention)
        let key = e.key;
        if (e.ctrlKey && e.key === '[') key = 'Escape';

        // Cmd-* shortcuts pass through (clipboard, save, etc.) unchanged
        if (e.metaKey) return;

        // In insert mode, only intercept ESC. Everything else types normally.
        if (_mode === MODE.INSERT) {
            if (handleInsertKey(key)) { e.preventDefault(); e.stopPropagation(); }
            return;
        }

        // In normal/visual modes, intercept everything that isn't a Cmd-chord
        let handled;
        if (_mode === MODE.VISUAL || _mode === MODE.VLINE) {
            handled = handleVisualKey(key, e);
        } else {
            handled = handleNormalKey(key, e);
        }
        if (handled) {
            e.preventDefault();
            e.stopPropagation();
        }
    }

    // ─────────────────────────────────────────────────────────────
    // Public API
    // ─────────────────────────────────────────────────────────────
    function enableVimLite(editor) {
        if (_enabled) return;
        _editor = editor;
        _enabled = true;

        // Inject the status pill (bottom-right of the editor container)
        let bar = document.getElementById('vim-status');
        if (!bar) {
            bar = document.createElement('div');
            bar.id = 'vim-status';
            bar.style.cssText = [
                'position:fixed', 'right:14px', 'bottom:10px',
                'padding:4px 10px', 'border-radius:6px',
                'font:600 11px/1 -apple-system,SF Pro,sans-serif',
                'color:#f0f0f5', 'background:#6366f1',
                'z-index:10000', 'pointer-events:none',
                'box-shadow:0 2px 8px rgba(0,0,0,0.3)',
            ].join(';');
            document.body.appendChild(bar);
        }
        _statusEl = bar;
        bar.style.display = 'block';

        // Capture-phase listener so we run BEFORE Monaco's own handlers
        // (gives us first dibs on hjkl etc. in normal mode).
        _keydownHandler = onKeyDown;
        document.addEventListener('keydown', _keydownHandler, true);

        setMode(MODE.NORMAL);
        localStorage.setItem('codebench.vim.enabled', '1');
        console.log('[vim-lite] enabled');
    }

    function disableVimLite() {
        if (!_enabled) return;
        _enabled = false;
        document.removeEventListener('keydown', _keydownHandler, true);
        _keydownHandler = null;
        if (_statusEl) _statusEl.style.display = 'none';
        if (_editor) _editor.updateOptions({ cursorStyle: 'line', cursorBlinking: 'blink' });
        _disposables.forEach(d => d.dispose && d.dispose());
        _disposables = [];
        localStorage.setItem('codebench.vim.enabled', '0');
        console.log('[vim-lite] disabled');
    }

    // Expose to the rest of the page + Swift bridge
    window.VimLite = {
        enable: enableVimLite,
        disable: disableVimLite,
        toggle: function (editor) {
            if (_enabled) disableVimLite();
            else enableVimLite(editor);
            return _enabled;
        },
        isEnabled: function () { return _enabled; },
    };
})();
