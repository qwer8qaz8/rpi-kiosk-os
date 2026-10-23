/**
 * RPi Kiosk Controller Card for Home Assistant
 * A custom Lovelace card to manage your Raspberry Pi Kiosk directly from Home Assistant.
 */

class RPiKioskCard extends HTMLElement {
  set hass(hass) {
    this._hass = hass;
    if (!this.content) {
      this.innerHTML = `
        <ha-card header="🖥️ Raspberry Pi Kiosk">
          <div class="card-content" style="padding: 16px;">
            <!-- Telemetry Bar -->
            <div style="display: flex; justify-content: space-between; align-items: center; margin-bottom: 16px; background: rgba(0,0,0,0.15); padding: 10px 14px; border-radius: 8px;">
              <div>
                <span style="font-size: 0.8em; opacity: 0.7; text-transform: uppercase;">Screen Status</span>
                <div id="kiosk-screen-badge" style="font-weight: bold; font-size: 1.1em; color: var(--primary-color);">Checking...</div>
              </div>
              <div style="text-align: right;">
                <span style="font-size: 0.8em; opacity: 0.7; text-transform: uppercase;">CPU Temp</span>
                <div id="kiosk-temp-badge" style="font-weight: bold; font-size: 1.1em;">--°C</div>
              </div>
            </div>

            <!-- Screen Power Toggle -->
            <div style="display: flex; justify-content: space-between; align-items: center; margin-bottom: 16px;">
              <span style="font-weight: 500;">Screen Power</span>
              <mwc-switch id="kiosk-power-toggle"></mwc-switch>
            </div>

            <!-- Brightness Slider -->
            <div style="margin-bottom: 16px;">
              <div style="display: flex; justify-content: space-between; font-size: 0.9em; margin-bottom: 4px;">
                <span>Screen Brightness</span>
                <span id="kiosk-brightness-val">100%</span>
              </div>
              <input type="range" id="kiosk-brightness-slider" min="5" max="100" step="5" value="100" style="width: 100%; accent-color: var(--primary-color); cursor: pointer;">
            </div>

            <!-- Quick Action Buttons -->
            <div style="display: grid; grid-template-columns: 1fr 1fr; gap: 10px; margin-bottom: 16px;">
              <mwc-button raised id="kiosk-btn-reload" style="--mdc-theme-primary: var(--warning-color, #f59e0b);">
                <ha-icon icon="mdi:refresh" style="margin-right: 6px;"></ha-icon> Reload
              </mwc-button>
              <mwc-button raised id="kiosk-btn-reboot" style="--mdc-theme-primary: var(--error-color, #ef4444);">
                <ha-icon icon="mdi:restart" style="margin-right: 6px;"></ha-icon> Reboot
              </mwc-button>
            </div>

            <!-- Remote URL Switcher -->
            <div style="border-top: 1px solid rgba(255,255,255,0.1); padding-top: 12px;">
              <span style="font-size: 0.85em; opacity: 0.8; display: block; margin-bottom: 6px;">Switch Active Dashboard URL:</span>
              <div style="display: flex; gap: 8px;">
                <input type="text" id="kiosk-url-input" placeholder="http://192.168.86.29:8123/lovelace/0?kiosk" style="flex: 1; padding: 8px 10px; border-radius: 6px; border: 1px solid var(--divider-color, #444); background: var(--card-background-color, #222); color: var(--primary-text-color, #fff);">
                <mwc-button raised id="kiosk-btn-send-url">Send</mwc-button>
              </div>
            </div>
          </div>
        </ha-card>
      `;

      this.content = this.querySelector(".card-content");

      // Bind events
      const toggle = this.querySelector("#kiosk-power-toggle");
      toggle.addEventListener("change", (e) => {
        const entityId = this._config.switch_entity || "switch.rpi_kiosk_screen";
        this._hass.callService("switch", e.target.checked ? "turn_on" : "turn_off", { entity_id: entityId });
      });

      const slider = this.querySelector("#kiosk-brightness-slider");
      slider.addEventListener("change", (e) => {
        const entityId = this._config.brightness_entity || "number.rpi_kiosk_brightness";
        this._hass.callService("number", "set_value", { entity_id: entityId, value: parseInt(e.target.value, 10) });
      });
      slider.addEventListener("input", (e) => {
        this.querySelector("#kiosk-brightness-val").textContent = e.target.value + "%";
      });

      this.querySelector("#kiosk-btn-reload").addEventListener("click", () => {
        const entityId = this._config.reload_button || "button.rpi_kiosk_reload";
        this._hass.callService("button", "press", { entity_id: entityId });
      });

      this.querySelector("#kiosk-btn-reboot").addEventListener("click", () => {
        if (!confirm("Are you sure you want to reboot the Raspberry Pi kiosk?")) return;
        const entityId = this._config.reboot_button || "button.rpi_kiosk_reboot";
        this._hass.callService("button", "press", { entity_id: entityId });
      });

      this.querySelector("#kiosk-btn-send-url").addEventListener("click", () => {
        const url = this.querySelector("#kiosk-url-input").value.trim();
        if (!url) return;
        const deviceId = this._config.device_id || "rpi_kiosk";
        this._hass.callService("mqtt", "publish", {
          topic: `rpi_kiosk/${deviceId}/url/set`,
          payload: url
        });
      });
    }

    this.updateCard();
  }

  updateCard() {
    if (!this._hass) return;

    const switchEntity = this._hass.states[this._config.switch_entity || "switch.rpi_kiosk_screen"];
    const tempEntity = this._hass.states[this._config.temperature_entity || "sensor.rpi_kiosk_cpu_temperature"];
    const brightEntity = this._hass.states[this._config.brightness_entity || "number.rpi_kiosk_brightness"];

    if (switchEntity) {
      const isTurnedOn = switchEntity.state === "on";
      const toggle = this.querySelector("#kiosk-power-toggle");
      if (toggle && toggle.checked !== isTurnedOn) {
        toggle.checked = isTurnedOn;
      }
      const badge = this.querySelector("#kiosk-screen-badge");
      if (badge) {
        badge.textContent = isTurnedOn ? "ONLINE (ON)" : "OFFLINE / SLEEP";
        badge.style.color = isTurnedOn ? "var(--success-color, #10b981)" : "var(--error-color, #ef4444)";
      }
    }

    if (tempEntity) {
      const tempBadge = this.querySelector("#kiosk-temp-badge");
      if (tempBadge) tempBadge.textContent = `${tempEntity.state}°C`;
    }

    if (brightEntity) {
      const slider = this.querySelector("#kiosk-brightness-slider");
      const label = this.querySelector("#kiosk-brightness-val");
      if (slider && document.activeElement !== slider) {
        slider.value = brightEntity.state;
      }
      if (label) label.textContent = `${brightEntity.state}%`;
    }
  }

  setConfig(config) {
    this._config = Object.assign({
      title: "RPi Kiosk",
      switch_entity: "switch.rpi_kiosk_screen",
      brightness_entity: "number.rpi_kiosk_brightness",
      temperature_entity: "sensor.rpi_kiosk_cpu_temperature",
      reload_button: "button.rpi_kiosk_reload",
      reboot_button: "button.rpi_kiosk_reboot",
      device_id: "rpi_kiosk"
    }, config);
  }

  getCardSize() {
    return 3;
  }
}

customElements.define("rpi-kiosk-card", RPiKioskCard);

// Register with Home Assistant custom cards preview
window.customCards = window.customCards || [];
window.customCards.push({
  type: "rpi-kiosk-card",
  name: "Raspberry Pi Kiosk Controller",
  description: "Control screen power, brightness, reload, and reboot your Raspberry Pi Kiosk."
});
