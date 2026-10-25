/**
 * sectioned-todo-card.js
 * High-performance, Unified Sectioned To-Do List Lovelace Card for Home Assistant
 * Features:
 * - Dynamic customizable sections (Add, Rename, Delete)
 * - Tasks within sections (Add, Check-off, Delete)
 * - Daily Repeating Tasks:
 *   - Toggle [🔁 Daily] when adding, or toggle on any task item
 *   - Displays stylish [🔁 Daily] badge
 *   - At end-of-day / midnight: ALL daily tasks (finished & unfinished) are removed
 *     and re-added as non-finished (needs_action), while non-daily tasks are untouched!
 */

const ICON_EDIT = `<svg viewBox="0 0 24 24" width="15" height="15" fill="currentColor" style="vertical-align: middle;"><path d="M20.71,7.04C21.1,6.65 21.1,6 20.71,5.63L18.37,3.29C18,2.9 17.35,2.9 16.96,3.29L15.12,5.12L18.87,8.87M3,17.25V21H6.75L17.81,9.93L14.06,6.18L3,17.25Z"/></svg>`;

const ICON_TRASH = `<svg viewBox="0 0 24 24" width="15" height="15" fill="currentColor" style="vertical-align: middle;"><path d="M19,4H15.5L14.5,3H9.5L8.5,4H5V6H19M6,19A2,2 0 0,0 8,21H16A2,2 0 0,0 18,19V7H6V19Z"/></svg>`;

const ICON_PLUS = `<svg viewBox="0 0 24 24" width="16" height="16" fill="currentColor" style="vertical-align: middle; margin-right: 3px;"><path d="M19,13H13V19H11V13H5V11H11V5H13V11H19V13Z"/></svg>`;

const ICON_REPEAT = `<svg viewBox="0 0 24 24" width="14" height="14" fill="currentColor" style="vertical-align: middle; margin-right: 2px;"><path d="M17,17H7V14L3,18L7,22V19H19V13H17M7,7H17V10L21,6L17,2V5H5V11H7V7Z"/></svg>`;

class SectionedTodoCard extends HTMLElement {
  constructor() {
    super();
    this.attachShadow({ mode: 'open' });
    this._config = {};
    this._hass = null;
    this._items = [];
    this._sections = new Set(['Shopping', 'Asher', 'Michael', 'Tina']);
    this._currentSection = 'Shopping';
    this._expandedSections = new Set();
    this._showAddSection = false;
    this._editingSection = null;
    this._confirmDeleteSection = null;
    this._isDailyNewTask = false;
    this._resetting = false;
    this._dailyResetTimer = null;
  }

  connectedCallback() {
    if (!this._dailyResetTimer) {
      this._dailyResetTimer = setInterval(() => {
        this._checkDailyReset();
      }, 30000);
    }
  }

  disconnectedCallback() {
    if (this._dailyResetTimer) {
      clearInterval(this._dailyResetTimer);
      this._dailyResetTimer = null;
    }
  }

  setConfig(config) {
    if (!config.entity) {
      config.entity = 'todo.shopping_list';
    }
    this._config = {
      title: config.title || 'Family Tasks & To-Do',
      entity: config.entity,
      default_sections: config.default_sections || ['Shopping', 'Asher', 'Michael', 'Tina'],
      ...config
    };
    (this._config.default_sections || []).forEach(s => this._sections.add(s));
    this._render();
  }

  set hass(hass) {
    const oldHass = this._hass;
    this._hass = hass;
    const entityId = this._config.entity;

    if (!oldHass || oldHass.states[entityId] !== hass.states[entityId]) {
      this._fetchItems();
    }
  }

  _getTodayStr() {
    const now = new Date();
    const y = now.getFullYear();
    const m = String(now.getMonth() + 1).padStart(2, '0');
    const d = String(now.getDate()).padStart(2, '0');
    return `${y}-${m}-${d}`;
  }

  async _fetchItems() {
    if (!this._hass || !this._config.entity) return;
    try {
      const res = await this._hass.callWS({
        type: 'todo/item/list',
        entity_id: this._config.entity
      });
      if (res && res.items) {
        this._items = res.items;
        this._extractSections();
        await this._checkDailyReset();
        this._render();
      }
    } catch (err) {
      console.warn('[sectioned-todo-card] Could not fetch items:', err);
    }
  }

  _extractSections() {
    this._items.forEach(item => {
      const parsed = this._parseItem(item);
      if (!parsed.isPlaceholder && parsed.section && parsed.section !== 'System') {
        this._sections.add(parsed.section);
      }
    });
  }

  _parseItem(item) {
    const rawSummary = item.summary || '';
    const m = rawSummary.match(/^\[(.*?)\]\s*(.*)$/);
    let section = 'General';
    let text = rawSummary;

    if (m && m[1]) {
      section = m[1].trim();
      text = m[2].trim();
    }

    const isSystem = section === 'System' || text === '__empty__' || text.includes('__daily_reset_');
    const isDaily = /\[daily\]/i.test(text) || text.includes('🔁') || /\[daily\]/i.test(rawSummary);
    const cleanText = text.replace(/\[daily\]/gi, '').replace(/🔁/g, '').trim();

    return {
      uid: item.uid,
      section: section,
      text: cleanText || text,
      rawText: text,
      status: item.status,
      isDaily: isDaily,
      isPlaceholder: isSystem
    };
  }

  /**
   * Daily Reset Engine
   * Detects when a new calendar day has started.
   * Removes all finished and unfinished [Daily] tasks and re-adds them as non-finished.
   * Completely preserves non-daily tasks.
   */
  async _checkDailyReset() {
    if (!this._hass || !this._config.entity || this._resetting) return;
    const todayStr = this._getTodayStr();
    const todayMarker = `__daily_reset_${todayStr}__`;

    // Check if reset marker for today is already recorded
    const hasTodayMarker = this._items.some(it => it.summary && it.summary.includes(todayMarker));
    if (hasTodayMarker) return;

    this._resetting = true;
    try {
      // Find old marker uids to clean up
      const oldMarkers = this._items
        .filter(it => it.summary && it.summary.includes('__daily_reset_') && !it.summary.includes(todayMarker))
        .map(it => it.uid);

      if (oldMarkers.length > 0) {
        await this._hass.callService('todo', 'remove_item', {
          entity_id: this._config.entity,
          item: oldMarkers
        });
      }

      // Collect all daily tasks (both completed and needs_action)
      const parsed = this._items.map(it => this._parseItem(it));
      const dailyTasks = parsed.filter(it => it.isDaily && !it.isPlaceholder);

      // Remove each daily task and re-add fresh as non-finished (needs_action)
      for (const task of dailyTasks) {
        await this._hass.callService('todo', 'remove_item', {
          entity_id: this._config.entity,
          item: [task.uid]
        });
        const summary = `[${task.section}] [Daily] ${task.text}`;
        await this._hass.callService('todo', 'add_item', {
          entity_id: this._config.entity,
          item: summary
        });
      }

      // Record marker for today
      await this._hass.callService('todo', 'add_item', {
        entity_id: this._config.entity,
        item: `[System] ${todayMarker}`
      });

      // Refetch clean items
      const res = await this._hass.callWS({
        type: 'todo/item/list',
        entity_id: this._config.entity
      });
      if (res && res.items) {
        this._items = res.items;
      }
    } catch (err) {
      console.warn('[sectioned-todo-card] Error in daily reset:', err);
    } finally {
      this._resetting = false;
    }
  }

  async _addItem(section, text, isDaily = false) {
    if (!text || !text.trim()) return;
    let cleanText = text.trim();
    const alreadyDaily = /\[daily\]/i.test(cleanText) || cleanText.includes('🔁');
    if (isDaily && !alreadyDaily) {
      cleanText = `[Daily] ${cleanText}`;
    }
    const summary = `[${section}] ${cleanText}`;
    await this._hass.callService('todo', 'add_item', {
      entity_id: this._config.entity,
      item: summary
    });
    this._isDailyNewTask = false;
    await this._fetchItems();
  }

  async _toggleDaily(uid, rawText, isCurrentlyDaily, section) {
    const clean = rawText.replace(/\[daily\]/gi, '').replace(/🔁/g, '').trim();
    const newSummary = isCurrentlyDaily
      ? `[${section}] ${clean}`
      : `[${section}] [Daily] ${clean}`;

    await this._hass.callService('todo', 'update_item', {
      entity_id: this._config.entity,
      item: uid,
      rename: newSummary
    });
    await this._fetchItems();
  }

  async _toggleItem(uid, currentStatus) {
    const newStatus = currentStatus === 'completed' ? 'needs_action' : 'completed';
    await this._hass.callService('todo', 'update_item', {
      entity_id: this._config.entity,
      item: uid,
      status: newStatus
    });
    await this._fetchItems();
  }

  async _removeItem(uid) {
    await this._hass.callService('todo', 'remove_item', {
      entity_id: this._config.entity,
      item: [uid]
    });
    await this._fetchItems();
  }

  async _createSection(name) {
    if (!name || !name.trim()) return;
    const cleanName = name.trim();
    this._sections.add(cleanName);
    this._currentSection = cleanName;
    this._showAddSection = false;
    await this._addItem(cleanName, '__empty__');
    this._render();
  }

  async _renameSection(oldName, newName) {
    if (!newName || !newName.trim() || oldName === newName) {
      this._editingSection = null;
      this._render();
      return;
    }
    const cleanNew = newName.trim();
    this._sections.delete(oldName);
    this._sections.add(cleanNew);

    if (this._currentSection === oldName) {
      this._currentSection = cleanNew;
    }

    const itemsToUpdate = this._items.map(it => this._parseItem(it)).filter(it => it.section === oldName);
    for (const it of itemsToUpdate) {
      const dailyTag = it.isDaily ? '[Daily] ' : '';
      await this._hass.callService('todo', 'update_item', {
        entity_id: this._config.entity,
        item: it.uid,
        rename: `[${cleanNew}] ${dailyTag}${it.text}`
      });
    }

    this._editingSection = null;
    await this._fetchItems();
  }

  async _deleteSection(sectionName) {
    this._sections.delete(sectionName);
    if (this._currentSection === sectionName) {
      this._currentSection = 'Shopping';
    }
    this._confirmDeleteSection = null;

    const itemsToDelete = this._items
      .map(it => this._parseItem(it))
      .filter(it => it.section === sectionName)
      .map(it => it.uid);

    if (itemsToDelete.length > 0) {
      await this._hass.callService('todo', 'remove_item', {
        entity_id: this._config.entity,
        item: itemsToDelete
      });
    }

    await this._fetchItems();
  }

  _render() {
    const parsedItems = this._items
      .map(it => this._parseItem(it))
      .filter(it => !it.isPlaceholder);

    const sectionsList = Array.from(this._sections);

    const sectionCounts = {};
    sectionsList.forEach(s => {
      sectionCounts[s] = parsedItems.filter(it => it.section === s && it.status !== 'completed').length;
    });

    const isAll = this._currentSection === 'All';

    let contentHtml = '';

    if (this._showAddSection) {
      contentHtml += `
        <div class="inline-box">
          <input type="text" id="new-section-input" placeholder="New Section Name (e.g. Liam, Errands)..." autofocus />
          <div class="btn-group">
            <button class="text-btn" id="cancel-add-sec">Cancel</button>
            <button class="primary-btn" id="confirm-add-sec">Add Section</button>
          </div>
        </div>
      `;
    }

    if (this._editingSection) {
      contentHtml += `
        <div class="inline-box">
          <div style="font-weight: 500; font-size: 0.85rem; color: var(--secondary-text-color, #757575);">Rename Section "${this._editingSection}"</div>
          <input type="text" id="rename-section-input" value="${this._editingSection}" autofocus />
          <div class="btn-group">
            <button class="text-btn" id="cancel-rename-sec">Cancel</button>
            <button class="primary-btn" id="confirm-rename-sec">Save Name</button>
          </div>
        </div>
      `;
    }

    if (this._confirmDeleteSection) {
      contentHtml += `
        <div class="inline-box" style="border: 1px solid rgba(244,67,54,0.3); background: rgba(244,67,54,0.06);">
          <div style="font-weight: 600; font-size: 0.9rem; color: var(--error-color, #f44336);">Delete "${this._confirmDeleteSection}" and all its tasks?</div>
          <div class="btn-group" style="margin-top: 6px;">
            <button class="text-btn" id="cancel-del-sec">Cancel</button>
            <button class="primary-btn danger-btn" id="confirm-del-sec" style="background: var(--error-color, #f44336); color: #fff;">Delete Section</button>
          </div>
        </div>
      `;
    }

    const renderTaskRow = (it) => `
      <div class="task-row ${it.status === 'completed' ? 'completed' : ''}">
        <label class="check-container">
          <input type="checkbox" ${it.status === 'completed' ? 'checked' : ''} class="task-toggle" data-uid="${it.uid}" data-status="${it.status}" />
          <span class="checkmark"></span>
          <span class="task-text">${it.text}</span>
          ${it.isDaily ? `<span class="daily-badge" title="Repeats daily - automatically resets to non-finished each morning">${ICON_REPEAT} Daily</span>` : ''}
        </label>
        <div class="task-actions">
          <button class="icon-btn toggle-daily-task ${it.isDaily ? 'active-repeat' : ''}" data-uid="${it.uid}" data-section="${it.section}" data-raw="${encodeURIComponent(it.rawText)}" data-daily="${it.isDaily ? '1' : '0'}" title="${it.isDaily ? 'Remove daily repeat' : 'Make this task repeat daily'}">${ICON_REPEAT}</button>
          <button class="del-task-btn" data-uid="${it.uid}" title="Delete task">✕</button>
        </div>
      </div>
    `;

    if (isAll) {
      // Accordion view for all sections
      sectionsList.forEach(sec => {
        const secItems = parsedItems.filter(it => it.section === sec);
        const activeItems = secItems.filter(it => it.status !== 'completed');
        const completedItems = secItems.filter(it => it.status === 'completed');
        const isExpanded = this._expandedSections.has(sec);

        contentHtml += `
          <div class="section-group">
            <div class="section-header" data-section="${sec}">
              <div class="sec-title-wrap">
                <span class="chevron">${isExpanded ? '▼' : '▶'}</span>
                <span class="sec-title">${sec}</span>
                <span class="sec-badge">${activeItems.length}</span>
              </div>
              <div class="sec-actions">
                <button class="icon-btn edit-sec" data-section="${sec}" title="Rename Section">${ICON_EDIT}</button>
                <button class="icon-btn del-sec" data-section="${sec}" title="Delete Section">${ICON_TRASH}</button>
              </div>
            </div>

            ${isExpanded ? `
              <div class="section-body">
                <div class="add-bar">
                  <input type="text" class="add-task-input" data-section="${sec}" placeholder="Add task to ${sec}..." />
                  <button class="daily-toggle-btn ${this._isDailyNewTask ? 'active' : ''}" title="Repeat daily (resets to non-finished each morning)">
                    ${ICON_REPEAT} <span>Daily</span>
                  </button>
                  <button class="add-task-btn" data-section="${sec}">＋</button>
                </div>

                <div class="task-list">
                  ${secItems.length === 0 ? `<div class="empty-hint">No items yet in ${sec}</div>` : ''}
                  ${activeItems.map(renderTaskRow).join('')}

                  ${completedItems.length > 0 ? `
                    <div class="completed-divider">Completed (${completedItems.length})</div>
                    ${completedItems.map(renderTaskRow).join('')}
                  ` : ''}
                </div>
              </div>
            ` : ''}
          </div>
        `;
      });
    } else {
      // Single Section View
      const sec = this._currentSection;
      const secItems = parsedItems.filter(it => it.section === sec);
      const activeItems = secItems.filter(it => it.status !== 'completed');
      const completedItems = secItems.filter(it => it.status === 'completed');

      contentHtml += `
        <div class="single-sec-wrap">
          <div class="single-sec-header">
            <div class="sec-title-large">
              <span>${sec}</span>
              <span class="sec-badge">${activeItems.length}</span>
            </div>
            <div class="sec-actions">
              <button class="pill-btn edit-sec" data-section="${sec}">${ICON_EDIT} <span>Rename</span></button>
              <button class="pill-btn del-sec danger" data-section="${sec}">${ICON_TRASH} <span>Remove</span></button>
            </div>
          </div>

          <div class="add-bar">
            <input type="text" class="add-task-input" data-section="${sec}" placeholder="Add task to ${sec}..." />
            <button class="daily-toggle-btn ${this._isDailyNewTask ? 'active' : ''}" title="Repeat daily (resets to non-finished each morning)">
              ${ICON_REPEAT} <span>Daily</span>
            </button>
            <button class="add-task-btn" data-section="${sec}">${ICON_PLUS} <span>Add Task</span></button>
          </div>

          <div class="task-list">
            ${secItems.length === 0 ? `<div class="empty-hint">No items yet in ${sec}. Add one above!</div>` : ''}
            ${activeItems.map(renderTaskRow).join('')}

            ${completedItems.length > 0 ? `
              <div class="completed-divider">Completed (${completedItems.length})</div>
              ${completedItems.map(renderTaskRow).join('')}
            ` : ''}
          </div>
        </div>
      `;
    }

    this.shadowRoot.innerHTML = `
      <style>
        :host {
          display: block;
        }
        ha-card {
          padding: 14px;
          background: var(--card-background-color, #ffffff);
          border-radius: 12px;
          box-shadow: var(--ha-card-box-shadow, 0 2px 4px rgba(0,0,0,0.05));
        }
        .header-wrap {
          display: flex;
          justify-content: space-between;
          align-items: center;
          margin-bottom: 10px;
        }
        .card-title {
          font-size: 1.15rem;
          font-weight: 600;
          margin: 0;
          color: var(--primary-text-color, #212121);
        }
        .pills-bar {
          display: flex;
          flex-wrap: wrap;
          gap: 6px;
          margin-bottom: 12px;
        }
        .pill {
          display: inline-flex;
          align-items: center;
          gap: 6px;
          padding: 5px 11px;
          border-radius: 20px;
          background: var(--secondary-background-color, rgba(0,0,0,0.05));
          color: var(--primary-text-color, #333333);
          font-size: 0.85rem;
          font-weight: 500;
          cursor: pointer;
          user-select: none;
          transition: all 0.15s ease-in-out;
          border: 1px solid transparent;
        }
        .pill:hover {
          background: var(--secondary-background-color, rgba(0,0,0,0.08));
        }
        .pill.active {
          background: var(--primary-color, #03a9f4);
          color: #ffffff;
          font-weight: 600;
        }
        .pill-add {
          background: transparent;
          border: 1px dashed var(--primary-color, #03a9f4);
          color: var(--primary-color, #03a9f4);
        }
        .pill-badge {
          background: rgba(0,0,0,0.12);
          border-radius: 10px;
          padding: 1px 6px;
          font-size: 0.75rem;
        }
        .pill.active .pill-badge {
          background: rgba(255,255,255,0.25);
        }
        .inline-box {
          background: var(--secondary-background-color, rgba(0,0,0,0.03));
          padding: 10px 12px;
          border-radius: 8px;
          margin-bottom: 10px;
          display: flex;
          flex-direction: column;
          gap: 8px;
        }
        .inline-box input {
          width: 100%;
          padding: 8px 12px;
          border-radius: 6px;
          border: 1px solid rgba(0,0,0,0.15);
          font-size: 0.95rem;
          box-sizing: border-box;
          outline: none;
        }
        .btn-group {
          display: flex;
          justify-content: flex-end;
          gap: 8px;
        }
        button {
          font-family: inherit;
          cursor: pointer;
        }
        .primary-btn {
          background: var(--primary-color, #03a9f4);
          color: #fff;
          border: none;
          padding: 6px 14px;
          border-radius: 6px;
          font-weight: 500;
        }
        .danger-btn {
          background: var(--error-color, #f44336) !important;
          color: #fff !important;
          border: none;
        }
        .text-btn {
          background: transparent;
          border: none;
          padding: 6px 12px;
          color: var(--secondary-text-color, #757575);
        }
        .section-group {
          border: 1px solid var(--divider-color, rgba(0,0,0,0.08));
          border-radius: 8px;
          margin-bottom: 8px;
          overflow: hidden;
        }
        .section-header {
          display: flex;
          justify-content: space-between;
          align-items: center;
          padding: 8px 12px;
          background: var(--secondary-background-color, rgba(0,0,0,0.02));
          cursor: pointer;
          user-select: none;
        }
        .sec-title-wrap {
          display: flex;
          align-items: center;
          gap: 8px;
        }
        .chevron {
          font-size: 0.75rem;
          color: var(--secondary-text-color, #757575);
        }
        .sec-title {
          font-weight: 600;
          font-size: 0.92rem;
        }
        .sec-badge {
          background: var(--secondary-background-color, rgba(0,0,0,0.08));
          color: var(--secondary-text-color, #616161);
          font-size: 0.75rem;
          padding: 2px 7px;
          border-radius: 10px;
        }
        .sec-actions {
          display: flex;
          align-items: center;
          gap: 6px;
        }
        .icon-btn {
          display: inline-flex;
          align-items: center;
          justify-content: center;
          background: transparent;
          border: none;
          padding: 5px;
          border-radius: 4px;
          color: var(--secondary-text-color, #757575);
          opacity: 0.75;
          transition: all 0.15s;
        }
        .icon-btn:hover {
          opacity: 1;
          background: var(--secondary-background-color, rgba(0,0,0,0.06));
          color: var(--primary-text-color, #212121);
        }
        .section-body {
          padding: 8px 12px;
        }
        .single-sec-header {
          display: flex;
          justify-content: space-between;
          align-items: center;
          margin-bottom: 10px;
          padding-bottom: 6px;
          border-bottom: 1px solid var(--divider-color, rgba(0,0,0,0.06));
        }
        .sec-title-large {
          font-size: 1.05rem;
          font-weight: 600;
          display: flex;
          align-items: center;
          gap: 8px;
        }
        .pill-btn {
          display: inline-flex;
          align-items: center;
          gap: 4px;
          background: var(--secondary-background-color, rgba(0,0,0,0.05));
          border: 1px solid var(--divider-color, rgba(0,0,0,0.1));
          border-radius: 6px;
          padding: 5px 10px;
          font-size: 0.8rem;
          color: var(--primary-text-color, #333333);
          cursor: pointer;
          transition: all 0.15s;
        }
        .pill-btn:hover {
          background: var(--secondary-background-color, rgba(0,0,0,0.1));
        }
        .pill-btn.danger {
          color: var(--error-color, #f44336);
          border-color: rgba(244,67,54,0.3);
        }
        .pill-btn.danger:hover {
          background: rgba(244,67,54,0.08);
        }
        .add-bar {
          display: flex;
          gap: 6px;
          margin-bottom: 10px;
          align-items: center;
        }
        .add-task-input {
          flex: 1;
          padding: 8px 12px;
          border-radius: 6px;
          border: 1px solid var(--divider-color, rgba(0,0,0,0.15));
          font-size: 0.9rem;
          outline: none;
        }
        .add-task-input:focus {
          border-color: var(--primary-color, #03a9f4);
        }
        .daily-toggle-btn {
          display: inline-flex;
          align-items: center;
          justify-content: center;
          gap: 4px;
          padding: 7px 11px;
          border-radius: 6px;
          border: 1px solid var(--divider-color, rgba(0,0,0,0.18));
          background: var(--secondary-background-color, rgba(0,0,0,0.03));
          color: var(--secondary-text-color, #616161);
          font-size: 0.82rem;
          font-weight: 500;
          cursor: pointer;
          transition: all 0.15s ease-in-out;
          user-select: none;
          white-space: nowrap;
        }
        .daily-toggle-btn:hover {
          background: var(--secondary-background-color, rgba(0,0,0,0.08));
        }
        .daily-toggle-btn.active {
          background: var(--primary-color, #03a9f4);
          color: #ffffff;
          border-color: var(--primary-color, #03a9f4);
          font-weight: 600;
        }
        .add-task-btn {
          display: inline-flex;
          align-items: center;
          justify-content: center;
          background: var(--primary-color, #03a9f4);
          color: #ffffff;
          border: none;
          border-radius: 6px;
          padding: 8px 14px;
          font-weight: 500;
          font-size: 0.9rem;
          cursor: pointer;
          white-space: nowrap;
        }
        .task-list {
          display: flex;
          flex-direction: column;
          gap: 5px;
        }
        .empty-hint {
          color: var(--secondary-text-color, #9e9e9e);
          font-size: 0.85rem;
          font-style: italic;
          padding: 6px 0;
          text-align: center;
        }
        .task-row {
          display: flex;
          align-items: center;
          justify-content: space-between;
          padding: 7px 10px;
          border-radius: 6px;
          background: var(--secondary-background-color, rgba(0,0,0,0.02));
          transition: background 0.15s;
        }
        .task-row:hover {
          background: var(--secondary-background-color, rgba(0,0,0,0.06));
        }
        .task-row.completed {
          opacity: 0.55;
        }
        .check-container {
          display: flex;
          align-items: center;
          gap: 10px;
          flex: 1;
          cursor: pointer;
          user-select: none;
        }
        .check-container input {
          display: none;
        }
        .checkmark {
          width: 18px;
          height: 18px;
          border: 2px solid var(--primary-color, #03a9f4);
          border-radius: 4px;
          display: inline-block;
          position: relative;
          flex-shrink: 0;
        }
        .check-container input:checked + .checkmark {
          background: var(--primary-color, #03a9f4);
        }
        .check-container input:checked + .checkmark:after {
          content: '';
          position: absolute;
          left: 5px;
          top: 2px;
          width: 4px;
          height: 9px;
          border: solid white;
          border-width: 0 2px 2px 0;
          transform: rotate(45deg);
        }
        .task-text {
          font-size: 0.92rem;
          color: var(--primary-text-color, #212121);
        }
        .task-row.completed .task-text {
          text-decoration: line-through;
        }
        .daily-badge {
          display: inline-flex;
          align-items: center;
          gap: 3px;
          background: rgba(3, 169, 244, 0.12);
          color: var(--primary-color, #03a9f4);
          font-size: 0.72rem;
          font-weight: 600;
          padding: 1px 7px;
          border-radius: 10px;
          margin-left: 6px;
          vertical-align: middle;
          border: 1px solid rgba(3, 169, 244, 0.25);
          user-select: none;
        }
        .task-actions {
          display: flex;
          align-items: center;
          gap: 4px;
        }
        .toggle-daily-task {
          font-size: 0.8rem;
          opacity: 0.4;
          padding: 3px 6px;
          border-radius: 4px;
          transition: all 0.15s;
        }
        .toggle-daily-task:hover {
          opacity: 1;
          background: var(--secondary-background-color, rgba(0,0,0,0.08));
        }
        .toggle-daily-task.active-repeat {
          opacity: 1;
          color: var(--primary-color, #03a9f4);
        }
        .del-task-btn {
          background: transparent;
          border: none;
          color: var(--secondary-text-color, #9e9e9e);
          font-size: 0.9rem;
          cursor: pointer;
          padding: 4px 8px;
          border-radius: 4px;
          transition: color 0.15s;
        }
        .del-task-btn:hover {
          color: var(--error-color, #f44336);
          background: rgba(244,67,54,0.08);
        }
        .completed-divider {
          font-size: 0.78rem;
          color: var(--secondary-text-color, #9e9e9e);
          margin-top: 8px;
          margin-bottom: 4px;
          text-transform: uppercase;
          letter-spacing: 0.5px;
          font-weight: 500;
        }
      </style>

      <ha-card>
        <div class="header-wrap">
          <h2 class="card-title">${this._config.title}</h2>
          <button class="pill pill-add" id="open-add-sec">＋ Add Section</button>
        </div>

        <div class="pills-bar">
          <div class="pill ${isAll ? 'active' : ''}" data-nav="All">
            <span>All</span>
            <span class="pill-badge">${parsedItems.filter(it => it.status !== 'completed').length}</span>
          </div>
          ${sectionsList.map(s => `
            <div class="pill ${this._currentSection === s ? 'active' : ''}" data-nav="${s}">
              <span>${s}</span>
              <span class="pill-badge">${sectionCounts[s] || 0}</span>
            </div>
          `).join('')}
        </div>

        ${contentHtml}
      </ha-card>
    `;

    this._bindEvents();
  }

  _bindEvents() {
    const root = this.shadowRoot;

    // Nav pills
    root.querySelectorAll('.pill[data-nav]').forEach(el => {
      el.addEventListener('click', () => {
        this._currentSection = el.getAttribute('data-nav');
        this._render();
      });
    });

    // Add Section button
    const openAddBtn = root.querySelector('#open-add-sec');
    if (openAddBtn) {
      openAddBtn.addEventListener('click', () => {
        this._showAddSection = true;
        this._editingSection = null;
        this._confirmDeleteSection = null;
        this._render();
        const input = root.querySelector('#new-section-input');
        if (input) input.focus();
      });
    }

    const cancelAddBtn = root.querySelector('#cancel-add-sec');
    if (cancelAddBtn) {
      cancelAddBtn.addEventListener('click', () => {
        this._showAddSection = false;
        this._render();
      });
    }

    const confirmAddBtn = root.querySelector('#confirm-add-sec');
    const newSecInput = root.querySelector('#new-section-input');
    if (confirmAddBtn && newSecInput) {
      const doAdd = () => this._createSection(newSecInput.value);
      confirmAddBtn.addEventListener('click', doAdd);
      newSecInput.addEventListener('keydown', (e) => {
        if (e.key === 'Enter') doAdd();
        if (e.key === 'Escape') {
          this._showAddSection = false;
          this._render();
        }
      });
    }

    // Rename Section buttons
    root.querySelectorAll('.edit-sec').forEach(btn => {
      btn.addEventListener('click', (e) => {
        e.stopPropagation();
        this._editingSection = btn.getAttribute('data-section');
        this._confirmDeleteSection = null;
        this._showAddSection = false;
        this._render();
        const input = root.querySelector('#rename-section-input');
        if (input) {
          input.focus();
          input.select();
        }
      });
    });

    const cancelRenameBtn = root.querySelector('#cancel-rename-sec');
    if (cancelRenameBtn) {
      cancelRenameBtn.addEventListener('click', () => {
        this._editingSection = null;
        this._render();
      });
    }

    const confirmRenameBtn = root.querySelector('#confirm-rename-sec');
    const renameSecInput = root.querySelector('#rename-section-input');
    if (confirmRenameBtn && renameSecInput) {
      const doRename = () => {
        this._renameSection(this._editingSection, renameSecInput.value);
      };
      confirmRenameBtn.addEventListener('click', doRename);
      renameSecInput.addEventListener('keydown', (e) => {
        if (e.key === 'Enter') doRename();
        if (e.key === 'Escape') {
          this._editingSection = null;
          this._render();
        }
      });
    }

    // Delete Section buttons
    root.querySelectorAll('.del-sec').forEach(btn => {
      btn.addEventListener('click', (e) => {
        e.stopPropagation();
        this._confirmDeleteSection = btn.getAttribute('data-section');
        this._editingSection = null;
        this._showAddSection = false;
        this._render();
      });
    });

    const cancelDelBtn = root.querySelector('#cancel-del-sec');
    if (cancelDelBtn) {
      cancelDelBtn.addEventListener('click', () => {
        this._confirmDeleteSection = null;
        this._render();
      });
    }

    const confirmDelBtn = root.querySelector('#confirm-del-sec');
    if (confirmDelBtn) {
      confirmDelBtn.addEventListener('click', () => {
        if (this._confirmDeleteSection) {
          this._deleteSection(this._confirmDeleteSection);
        }
      });
    }

    // Toggle Accordion Group in All view
    root.querySelectorAll('.section-header').forEach(el => {
      el.addEventListener('click', (e) => {
        if (e.target.closest('.sec-actions')) return;
        const sec = el.getAttribute('data-section');
        if (this._expandedSections.has(sec)) {
          this._expandedSections.delete(sec);
        } else {
          this._expandedSections.add(sec);
        }
        this._render();
      });
    });

    // Toggle Daily button for New Task
    root.querySelectorAll('.daily-toggle-btn').forEach(btn => {
      btn.addEventListener('click', () => {
        const bar = btn.closest('.add-bar');
        const input = bar ? bar.querySelector('.add-task-input') : null;
        const currentVal = input ? input.value : '';
        this._isDailyNewTask = !this._isDailyNewTask;
        this._render();
        if (currentVal) {
          const sec = btn.getAttribute('data-section') || this._currentSection;
          const newInput = root.querySelector(`.add-task-input[data-section="${sec}"]`) || root.querySelector('.add-task-input');
          if (newInput) {
            newInput.value = currentVal;
            newInput.focus();
          }
        }
      });
    });

    // Add task buttons & Enter key
    root.querySelectorAll('.add-task-btn').forEach(btn => {
      btn.addEventListener('click', () => {
        const sec = btn.getAttribute('data-section');
        const input = root.querySelector(`.add-task-input[data-section="${sec}"]`);
        if (input && input.value) {
          this._addItem(sec, input.value, this._isDailyNewTask);
          input.value = '';
        }
      });
    });

    root.querySelectorAll('.add-task-input').forEach(input => {
      input.addEventListener('keydown', (e) => {
        if (e.key === 'Enter' && input.value) {
          const sec = input.getAttribute('data-section');
          this._addItem(sec, input.value, this._isDailyNewTask);
          input.value = '';
        }
      });
    });

    // Toggle Daily on existing task
    root.querySelectorAll('.toggle-daily-task').forEach(btn => {
      btn.addEventListener('click', () => {
        const uid = btn.getAttribute('data-uid');
        const section = btn.getAttribute('data-section');
        const rawText = decodeURIComponent(btn.getAttribute('data-raw') || '');
        const isDaily = btn.getAttribute('data-daily') === '1';
        this._toggleDaily(uid, rawText, isDaily, section);
      });
    });

    // Toggle Task Complete
    root.querySelectorAll('.task-toggle').forEach(chk => {
      chk.addEventListener('change', () => {
        const uid = chk.getAttribute('data-uid');
        const status = chk.getAttribute('data-status');
        this._toggleItem(uid, status);
      });
    });

    // Delete Task
    root.querySelectorAll('.del-task-btn').forEach(btn => {
      btn.addEventListener('click', () => {
        const uid = btn.getAttribute('data-uid');
        this._removeItem(uid);
      });
    });
  }
}

// Global hook to ensure the top-bar hamburger / sandwich menu is permanently hidden
function hideHomeAssistantMenu() {
  try {
    const ha = document.querySelector('home-assistant');
    if (!ha) return;

    function walk(node) {
      if (!node) return;
      if (node.tagName && (node.tagName.toLowerCase() === 'ha-menu-button' || node.getAttribute('slot') === 'navigationIcon')) {
        node.style.setProperty('display', 'none', 'important');
        node.style.setProperty('visibility', 'hidden', 'important');
        node.style.setProperty('width', '0', 'important');
        try { node.remove(); } catch(e) {}
      }
      if (node.querySelectorAll) {
        node.querySelectorAll('ha-menu-button, [slot="navigationIcon"]').forEach(b => {
          b.style.setProperty('display', 'none', 'important');
          b.style.setProperty('visibility', 'hidden', 'important');
          b.style.setProperty('width', '0', 'important');
          try { b.remove(); } catch(e) {}
        });
      }
      if (node.children) {
        for (const child of node.children) walk(child);
      }
      if (node.shadowRoot) {
        if (!node.shadowRoot.querySelector('#hide-ha-menu-style')) {
          const s = document.createElement('style');
          s.id = 'hide-ha-menu-style';
          s.textContent = `
            ha-menu-button, [slot="navigationIcon"] {
              display: none !important;
              visibility: hidden !important;
              width: 0 !important;
              max-width: 0 !important;
              opacity: 0 !important;
              pointer-events: none !important;
            }
          `;
          try { node.shadowRoot.appendChild(s); } catch(e) {}
        }
        walk(node.shadowRoot);
      }
    }
    walk(ha);
  } catch(e) {}
}

setInterval(hideHomeAssistantMenu, 600);
setTimeout(hideHomeAssistantMenu, 100);

customElements.define('sectioned-todo-card', SectionedTodoCard);
window.customCards = window.customCards || [];
window.customCards.push({
  type: 'sectioned-todo-card',
  name: 'Sectioned To-Do Card',
  description: 'Manage To-Do tasks organized into dynamic, customizable sections with daily repeating reset.'
});
