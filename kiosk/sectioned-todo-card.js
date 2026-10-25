/**
 * sectioned-todo-card.js
 * High-performance, Unified Sectioned To-Do List Lovelace Card for Home Assistant
 * Allows full management of sections (Add, Rename, Delete) and tasks within each section.
 */

class SectionedTodoCard extends HTMLElement {
  constructor() {
    super();
    this.attachShadow({ mode: 'open' });
    this._config = {};
    this._hass = null;
    this._items = [];
    this._sections = new Set(['Shopping', 'Asher', 'Michael', 'Tina']);
    this._currentSection = 'Shopping';
    this._collapsedSections = new Set();
    this._showAddSection = false;
    this._editingSection = null;
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
    if (!confirm(`Are you sure you want to delete section "${sectionName}" and all its tasks?`)) {
      return;
    }
    this._sections.delete(sectionName);
    if (this._currentSection === sectionName) {
      this._currentSection = 'All';
    }

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
            <button class="primary-btn" id="confirm-add-sec">Create</button>
            <button class="text-btn" id="cancel-add-sec">Cancel</button>
          </div>
        </div>
      `;
    }

    if (isAll) {
      // Display all sections as clean collapsible groups
      sectionsList.forEach(sec => {
        const secItems = parsedItems.filter(it => it.section === sec);
        const activeItems = secItems.filter(it => it.status !== 'completed');
        const completedItems = secItems.filter(it => it.status === 'completed');
        const isCollapsed = this._collapsedSections.has(sec);

        contentHtml += `
          <div class="section-group">
            <div class="section-header" data-section="${sec}">
              <div class="sec-title-wrap">
                <span class="chevron">${isCollapsed ? '▶' : '▼'}</span>
                <span class="sec-title">${sec}</span>
                <span class="sec-badge">${activeItems.length}</span>
              </div>
              <div class="sec-actions">
                <button class="icon-btn edit-sec" data-section="${sec}" title="Rename Section">✏️</button>
                <button class="icon-btn del-sec" data-section="${sec}" title="Delete Section">🗑️</button>
              </div>
            </div>

            ${!isCollapsed ? `
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
              <button class="pill-btn edit-sec" data-section="${sec}">✏️ Rename</button>
              <button class="pill-btn del-sec danger" data-section="${sec}">🗑️ Remove</button>
            </div>
          </div>

          <div class="add-bar">
            <input type="text" class="add-task-input" data-section="${sec}" placeholder="Add task to ${sec}..." />
            <button class="add-task-btn" data-section="${sec}">＋ Add Task</button>
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
          font-family: var(--paper-font-body1_-_font-family, Roboto, sans-serif);
        }
        ha-card {
          background: var(--ha-card-background, var(--card-background-color, #ffffff));
          border-radius: var(--ha-card-border-radius, 12px);
          border: 1px solid var(--ha-card-border-color, rgba(0,0,0,0.08));
          padding: 16px;
          box-shadow: var(--ha-card-box-shadow, none);
          box-sizing: border-box;
        }
        .header-wrap {
          display: flex;
          justify-content: space-between;
          align-items: center;
          margin-bottom: 12px;
        }
        .card-title {
          font-size: 1.15rem;
          font-weight: 600;
          color: var(--primary-text-color, #212121);
          margin: 0;
        }
        .pills-bar {
          display: flex;
          flex-wrap: wrap;
          gap: 6px;
          margin-bottom: 12px;
        }
        .pill {
          padding: 6px 12px;
          border-radius: 16px;
          background: var(--secondary-background-color, rgba(0,0,0,0.05));
          color: var(--primary-text-color, #212121);
          font-size: 0.85rem;
          font-weight: 500;
          cursor: pointer;
          white-space: nowrap;
          border: 1px solid transparent;
          transition: all 0.15s ease;
          display: flex;
          align-items: center;
          gap: 6px;
          user-select: none;
        }
        .pill:hover {
          background: var(--primary-color, #03a9f4);
          color: #ffffff;
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
          padding: 12px;
          border-radius: 8px;
          margin-bottom: 12px;
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
        .text-btn {
          background: transparent;
          border: none;
          padding: 6px 12px;
          color: var(--secondary-text-color, #757575);
        }
        .section-group {
          border: 1px solid var(--divider-color, rgba(0,0,0,0.08));
          border-radius: 8px;
          margin-bottom: 10px;
          overflow: hidden;
        }
        .section-header {
          display: flex;
          justify-content: space-between;
          align-items: center;
          padding: 10px 12px;
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
          font-size: 0.95rem;
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
          gap: 4px;
        }
        .icon-btn {
          background: transparent;
          border: none;
          padding: 4px;
          font-size: 0.85rem;
          opacity: 0.6;
          transition: opacity 0.15s;
        }
        .icon-btn:hover {
          opacity: 1;
        }
        .section-body {
          padding: 10px 12px;
        }
        .single-sec-header {
          display: flex;
          justify-content: space-between;
          align-items: center;
          margin-bottom: 12px;
          padding-bottom: 8px;
          border-bottom: 1px solid var(--divider-color, rgba(0,0,0,0.06));
        }
        .sec-title-large {
          font-size: 1.1rem;
          font-weight: 600;
          display: flex;
          align-items: center;
          gap: 8px;
        }
        .pill-btn {
          background: var(--secondary-background-color, rgba(0,0,0,0.05));
          border: 1px solid var(--divider-color, rgba(0,0,0,0.1));
          border-radius: 6px;
          padding: 4px 10px;
          font-size: 0.8rem;
          font-weight: 500;
        }
        .pill-btn.danger {
          color: #d32f2f;
          border-color: rgba(211, 47, 47, 0.2);
        }
        .add-bar {
          display: flex;
          gap: 8px;
          margin-bottom: 12px;
        }
        .add-task-input {
          flex: 1;
          padding: 8px 12px;
          border-radius: 6px;
          border: 1px solid var(--divider-color, rgba(0,0,0,0.15));
          font-size: 0.9rem;
          outline: none;
        }
        .add-task-btn {
          background: var(--primary-color, #03a9f4);
          color: #fff;
          border: none;
          padding: 8px 14px;
          border-radius: 6px;
          font-weight: 600;
        }
        .task-list {
          display: flex;
          flex-direction: column;
          gap: 6px;
        }
        .task-row {
          display: flex;
          align-items: center;
          justify-content: space-between;
          padding: 6px 8px;
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
          font-size: 0.95rem;
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
          padding: 4px 8px;
          border-radius: 4px;
        }
        .del-task-btn:hover {
          color: #d32f2f;
          background: rgba(211, 47, 47, 0.08);
        }
        .completed-divider {
          font-size: 0.75rem;
          font-weight: 600;
          color: var(--secondary-text-color, #757575);
          text-transform: uppercase;
          margin-top: 8px;
          margin-bottom: 2px;
          letter-spacing: 0.5px;
        }
        .empty-hint {
          padding: 10px;
          text-align: center;
          color: var(--secondary-text-color, #9e9e9e);
          font-size: 0.85rem;
          font-style: italic;
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

    // Toggle Accordion Group
    root.querySelectorAll('.section-header').forEach(el => {
      el.addEventListener('click', (e) => {
        if (e.target.closest('.sec-actions')) return;
        const sec = el.getAttribute('data-section');
        if (this._collapsedSections.has(sec)) {
          this._collapsedSections.delete(sec);
        } else {
          this._collapsedSections.add(sec);
        }
        this._render();
      });
    });

    // Rename Section
    root.querySelectorAll('.edit-sec').forEach(btn => {
      btn.addEventListener('click', (e) => {
        e.stopPropagation();
        const sec = btn.getAttribute('data-section');
        const newName = prompt(`Rename section "${sec}" to:`, sec);
        if (newName) this._renameSection(sec, newName);
      });
    });

    // Delete Section
    root.querySelectorAll('.del-sec').forEach(btn => {
      btn.addEventListener('click', (e) => {
        e.stopPropagation();
        const sec = btn.getAttribute('data-section');
        this._deleteSection(sec);
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

customElements.define('sectioned-todo-card', SectionedTodoCard);
window.customCards = window.customCards || [];
window.customCards.push({
  type: 'sectioned-todo-card',
  name: 'Sectioned To-Do Card',
  description: 'Manage To-Do tasks organized into dynamic, customizable sections.'
});
