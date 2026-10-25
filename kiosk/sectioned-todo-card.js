/**
 * sectioned-todo-card.js
 * High-performance, Unified Sectioned To-Do List Lovelace Card for Home Assistant
 * Allows full management of sections (Add, Rename, Delete) and tasks within each section.
 */

const ICON_EDIT = `<svg viewBox="0 0 24 24" width="15" height="15" fill="currentColor" style="vertical-align: middle;"><path d="M20.71,7.04C21.1,6.65 21.1,6 20.71,5.63L18.37,3.29C18,2.9 17.35,2.9 16.96,3.29L15.12,5.12L18.87,8.87M3,17.25V21H6.75L17.81,9.93L14.06,6.18L3,17.25Z"/></svg>`;

const ICON_TRASH = `<svg viewBox="0 0 24 24" width="15" height="15" fill="currentColor" style="vertical-align: middle;"><path d="M19,4H15.5L14.5,3H9.5L8.5,4H5V6H19M6,19A2,2 0 0,0 8,21H16A2,2 0 0,0 18,19V7H6V19Z"/></svg>`;

const ICON_PLUS = `<svg viewBox="0 0 24 24" width="16" height="16" fill="currentColor" style="vertical-align: middle; margin-right: 3px;"><path d="M19,13H13V19H11V13H5V11H11V5H13V11H19V13Z"/></svg>`;

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
        this._render();
      }
    } catch (err) {
      console.warn('[sectioned-todo-card] Could not fetch items:', err);
    }
  }

  _extractSections() {
    this._items.forEach(item => {
      const m = item.summary.match(/^\[(.*?)\]\s*(.*)$/);
      if (m && m[1]) {
        this._sections.add(m[1].trim());
      }
    });
  }

  _parseItem(item) {
    const m = item.summary.match(/^\[(.*?)\]\s*(.*)$/);
    if (m && m[1]) {
      return {
        uid: item.uid,
        section: m[1].trim(),
        text: m[2].trim(),
        status: item.status,
        isPlaceholder: m[2].trim() === '__empty__'
      };
    }
    return {
      uid: item.uid,
      section: 'General',
      text: item.summary,
      status: item.status,
      isPlaceholder: item.summary === '__empty__'
    };
  }

  async _addItem(section, text) {
    if (!text || !text.trim()) return;
    const summary = `[${section}] ${text.trim()}`;
    await this._hass.callService('todo', 'add_item', {
      entity_id: this._config.entity,
      item: summary
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
    // Add placeholder so it persists in Home Assistant
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
      await this._hass.callService('todo', 'update_item', {
        entity_id: this._config.entity,
        item: it.uid,
        rename: `[${cleanNew}] ${it.text}`
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

    if (isAll) {
      // Accordion view for all sections (collapsed by default to prevent vertical overflow)
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
                  <button class="add-task-btn" data-section="${sec}">＋</button>
                </div>

                <div class="task-list">
                  ${secItems.length === 0 ? `<div class="empty-hint">No items yet in ${sec}</div>` : ''}
                  ${activeItems.map(it => `
                    <div class="task-row">
                      <label class="check-container">
                        <input type="checkbox" class="task-toggle" data-uid="${it.uid}" data-status="${it.status}" />
                        <span class="checkmark"></span>
                        <span class="task-text">${it.text}</span>
                      </label>
                      <button class="del-task-btn" data-uid="${it.uid}">✕</button>
                    </div>
                  `).join('')}

                  ${completedItems.length > 0 ? `
                    <div class="completed-divider">Completed (${completedItems.length})</div>
                    ${completedItems.map(it => `
                      <div class="task-row completed">
                        <label class="check-container">
                          <input type="checkbox" checked class="task-toggle" data-uid="${it.uid}" data-status="${it.status}" />
                          <span class="checkmark"></span>
                          <span class="task-text">${it.text}</span>
                        </label>
                        <button class="del-task-btn" data-uid="${it.uid}">✕</button>
                      </div>
                    `).join('')}
                  ` : ''}
                </div>
              </div>
            ` : ''}
          </div>
        `;
      });
    } else {
      // Single Section View (compact, focused)
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
            <button class="add-task-btn" data-section="${sec}">${ICON_PLUS} <span>Add Task</span></button>
          </div>

          <div class="task-list">
            ${secItems.length === 0 ? `<div class="empty-hint">No items yet in ${sec}. Add one above!</div>` : ''}
            ${activeItems.map(it => `
              <div class="task-row">
                <label class="check-container">
                  <input type="checkbox" class="task-toggle" data-uid="${it.uid}" data-status="${it.status}" />
                  <span class="checkmark"></span>
                  <span class="task-text">${it.text}</span>
                </label>
                <button class="del-task-btn" data-uid="${it.uid}">✕</button>
              </div>
            `).join('')}

            ${completedItems.length > 0 ? `
              <div class="completed-divider">Completed (${completedItems.length})</div>
              ${completedItems.map(it => `
                <div class="task-row completed">
                  <label class="check-container">
                    <input type="checkbox" checked class="task-toggle" data-uid="${it.uid}" data-status="${it.status}" />
                    <span class="checkmark"></span>
                    <span class="task-text">${it.text}</span>
                  </label>
                  <button class="del-task-btn" data-uid="${it.uid}">✕</button>
                </div>
              `).join('')}
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
          gap: 8px;
          margin-bottom: 10px;
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

    // Add task buttons & Enter key
    root.querySelectorAll('.add-task-btn').forEach(btn => {
      btn.addEventListener('click', () => {
        const sec = btn.getAttribute('data-section');
        const input = root.querySelector(`.add-task-input[data-section="${sec}"]`);
        if (input && input.value) {
          this._addItem(sec, input.value);
          input.value = '';
        }
      });
    });

    root.querySelectorAll('.add-task-input').forEach(input => {
      input.addEventListener('keydown', (e) => {
        if (e.key === 'Enter' && input.value) {
          const sec = input.getAttribute('data-section');
          this._addItem(sec, input.value);
          input.value = '';
        }
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
  description: 'Manage To-Do tasks organized into dynamic, customizable sections.'
});
