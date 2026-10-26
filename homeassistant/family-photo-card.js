/**
 * Family Photo Display & Ambient Picture Frame Card for Home Assistant Lovelace
 * 
 * Features:
 * - High-resolution digital photo frame with Ken Burns pan/zoom and smooth crossfade
 * - Live ambient digital clock, date, and weather overlay
 * - Direct photo upload right from the UI (drag-and-drop or file picker)
 * - Tap anywhere navigation to return to the main dashboard
 * - Touch swipe / navigation buttons (Previous, Next, Pause/Play)
 * - Automatic rotation every 10 seconds
 */

class FamilyPhotoCard extends HTMLElement {
  constructor() {
    super();
    this.attachShadow({ mode: 'open' });
    this._hass = null;
    this.photos = [
      '/local/photos/photo1.jpg',
      '/local/photos/photo2.jpg',
      '/local/photos/photo3.jpg'
    ];
    this.currentIndex = 0;
    this.timer = null;
    this.clockTimer = null;
    this.isPaused = false;
    this.config = {
      interval: 10,
      show_clock: true,
      show_weather: true,
      weather_entity: 'weather.forecast_home',
      photos: []
    };
  }

  setConfig(config) {
    this.config = {
      interval: 10,
      show_clock: true,
      show_weather: true,
      weather_entity: 'weather.forecast_home',
      ...config
    };

    if (this.config.photos && this.config.photos.length > 0) {
      this.photos = [...this.config.photos];
    } else {
      // Check localStorage for saved family uploads
      try {
        const saved = localStorage.getItem('kiosk_family_photos');
        if (saved) {
          const parsed = JSON.parse(saved);
          if (Array.isArray(parsed) && parsed.length > 0) {
            this.photos = parsed;
          }
        }
      } catch (e) {}
    }

    this.render();
    this.startSlideshow();
    this.startClock();
  }

  set hass(hass) {
    this._hass = hass;
    this.updateWeather();
  }

  connectedCallback() {
    this.startSlideshow();
    this.startClock();
  }

  disconnectedCallback() {
    if (this.timer) clearInterval(this.timer);
    if (this.clockTimer) clearInterval(this.clockTimer);
  }

  startSlideshow() {
    if (this.timer) clearInterval(this.timer);
    if (this.isPaused) return;
    const intervalMs = (this.config.interval || 10) * 1000;
    this.timer = setInterval(() => {
      this.nextPhoto();
    }, intervalMs);
  }

  startClock() {
    if (this.clockTimer) clearInterval(this.clockTimer);
    this.updateClock();
    this.clockTimer = setInterval(() => this.updateClock(), 1000);
  }

  nextPhoto() {
    if (this.photos.length <= 1) return;
    this.currentIndex = (this.currentIndex + 1) % this.photos.length;
    this.transitionToPhoto();
  }

  prevPhoto() {
    if (this.photos.length <= 1) return;
    this.currentIndex = (this.currentIndex - 1 + this.photos.length) % this.photos.length;
    this.transitionToPhoto();
  }

  transitionToPhoto() {
    const root = this.shadowRoot;
    if (!root) return;
    const imgA = root.getElementById('photo-a');
    const imgB = root.getElementById('photo-b');
    if (!imgA || !imgB) return;

    const nextUrl = this.photos[this.currentIndex];

    if (imgA.classList.contains('active')) {
      imgB.src = nextUrl;
      imgB.classList.add('active');
      imgA.classList.remove('active');
    } else {
      imgA.src = nextUrl;
      imgA.classList.add('active');
      imgB.classList.remove('active');
    }
  }

  updateClock() {
    const root = this.shadowRoot;
    if (!root) return;
    const timeEl = root.getElementById('ambient-time');
    const dateEl = root.getElementById('ambient-date');
    if (!timeEl || !dateEl) return;

    const now = new Date();
    timeEl.textContent = now.toLocaleTimeString([], { hour: 'numeric', minute: '2-digit' });
    dateEl.textContent = now.toLocaleDateString([], { weekday: 'long', month: 'long', day: 'numeric' });
  }

  updateWeather() {
    const root = this.shadowRoot;
    if (!root || !this._hass) return;
    const weatherEl = root.getElementById('ambient-weather');
    if (!weatherEl) return;

    const entityId = this.config.weather_entity || 'weather.forecast_home';
    const stateObj = this._hass.states[entityId];
    if (stateObj) {
      const temp = stateObj.attributes.temperature;
      const unit = stateObj.attributes.temperature_unit || '°F';
      const cond = stateObj.state.replace(/_/g, ' ');
      weatherEl.textContent = `${temp}${unit} • ${cond.charAt(0).toUpperCase() + cond.slice(1)}`;
      weatherEl.style.display = 'block';
    }
  }

  render() {
    if (!this.shadowRoot) return;
    const initialUrl = this.photos[this.currentIndex] || '';

    this.shadowRoot.innerHTML = `
      <style>
        :host {
          display: block;
          position: relative;
          width: 100%;
          height: 100%;
          min-height: 520px;
          user-select: none;
          background: #000;
          overflow: hidden;
          font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif;
        }

        .frame-container {
          position: relative;
          width: 100%;
          height: 100%;
          min-height: calc(100vh - 64px);
          overflow: hidden;
          background: #000000;
          display: flex;
          align-items: center;
          justify-content: center;
        }

        .photo-layer {
          position: absolute;
          inset: 0;
          width: 100%;
          height: 100%;
          object-fit: cover;
          opacity: 0;
          transition: opacity 1.8s ease-in-out, transform 12s ease-out;
          transform: scale(1);
        }

        .photo-layer.active {
          opacity: 1;
          transform: scale(1.05);
        }

        /* Subtle gradient overlays for ambient text readability */
        .scrim-overlay {
          position: absolute;
          inset: 0;
          background: linear-gradient(180deg, rgba(0,0,0,0.4) 0%, transparent 25%, transparent 60%, rgba(0,0,0,0.7) 100%);
          pointer-events: none;
          z-index: 5;
        }

        /* Ambient Info Overlay (Clock & Weather) */
        .ambient-info {
          position: absolute;
          bottom: 28px;
          left: 36px;
          z-index: 10;
          color: white;
          text-shadow: 0 2px 10px rgba(0,0,0,0.8);
          pointer-events: none;
        }

        .time-display {
          font-size: 3.6rem;
          font-weight: 300;
          letter-spacing: -0.03em;
          line-height: 1;
          margin-bottom: 4px;
        }

        .date-display {
          font-size: 1.25rem;
          font-weight: 500;
          opacity: 0.9;
          margin-bottom: 4px;
        }

        .weather-display {
          font-size: 1.1rem;
          font-weight: 600;
          opacity: 0.85;
          color: #38bdf8;
        }

        /* Control Toolbar */
        .controls-toolbar {
          position: absolute;
          top: 20px;
          right: 24px;
          z-index: 20;
          display: flex;
          gap: 10px;
          opacity: 0;
          transition: opacity 0.3s ease;
          background: rgba(15, 23, 42, 0.75);
          backdrop-filter: blur(12px);
          padding: 8px 14px;
          border-radius: 30px;
          border: 1px solid rgba(255, 255, 255, 0.15);
        }

        .frame-container:hover .controls-toolbar,
        .controls-toolbar:focus-within {
          opacity: 1;
        }

        .ctrl-btn {
          background: transparent;
          border: none;
          color: white;
          font-size: 0.95rem;
          font-weight: 600;
          display: inline-flex;
          align-items: center;
          gap: 6px;
          padding: 6px 12px;
          border-radius: 20px;
          cursor: pointer;
          transition: background 0.2s;
        }

        .ctrl-btn:hover {
          background: rgba(255, 255, 255, 0.2);
        }

        .ctrl-btn-primary {
          background: #0284c7;
        }
        .ctrl-btn-primary:hover {
          background: #0369a1;
        }

        /* Tap anywhere hint */
        .exit-hint {
          position: absolute;
          top: 24px;
          left: 36px;
          z-index: 10;
          background: rgba(0, 0, 0, 0.5);
          color: #e2e8f0;
          backdrop-filter: blur(8px);
          padding: 6px 14px;
          border-radius: 20px;
          font-size: 0.82rem;
          font-weight: 600;
          border: 1px solid rgba(255, 255, 255, 0.1);
          cursor: pointer;
          transition: all 0.2s;
        }

        .exit-hint:hover {
          background: rgba(0, 0, 0, 0.8);
          color: white;
        }

        .file-input {
          display: none;
        }
      </style>

      <div class="frame-container" id="frame-container">
        <!-- Two photo layers for crossfading -->
        <img class="photo-layer active" id="photo-a" src="${initialUrl}" alt="Family Photo" />
        <img class="photo-layer" id="photo-b" src="" alt="Family Photo" />

        <div class="scrim-overlay"></div>

        <!-- Exit back to Dashboard button -->
        <div class="exit-hint" id="btn-back">
          ← Back to Dashboard
        </div>

        <!-- Ambient Clock & Weather -->
        <div class="ambient-info">
          <div class="time-display" id="ambient-time">--:--</div>
          <div class="date-display" id="ambient-date">Loading date...</div>
          <div class="weather-display" id="ambient-weather" style="display: none;"></div>
        </div>

        <!-- Top Right Controls -->
        <div class="controls-toolbar" id="controls">
          <button class="ctrl-btn ctrl-btn-primary" id="btn-upload">
            📁 Add Photo
          </button>
          <button class="ctrl-btn" id="btn-prev" title="Previous Photo">
            ⏮️
          </button>
          <button class="ctrl-btn" id="btn-play-pause" title="Play/Pause">
            ⏸️
          </button>
          <button class="ctrl-btn" id="btn-next" title="Next Photo">
            ⏭️
          </button>
        </div>

        <input type="file" id="file-input" class="file-input" accept="image/*" multiple />
      </div>
    `;

    this.attachEvents();
    this.updateClock();
    this.updateWeather();
  }

  attachEvents() {
    const root = this.shadowRoot;
    if (!root) return;

    const container = root.getElementById('frame-container');
    const btnBack = root.getElementById('btn-back');
    const btnUpload = root.getElementById('btn-upload');
    const btnPrev = root.getElementById('btn-prev');
    const btnNext = root.getElementById('btn-next');
    const btnPlayPause = root.getElementById('btn-play-pause');
    const fileInput = root.getElementById('file-input');

    // Return to dashboard
    const goBack = () => {
      window.history.pushState(null, '', '/dashboard-kiosk/0');
      window.dispatchEvent(new CustomEvent('location-changed'));
    };

    if (btnBack) btnBack.onclick = (e) => {
      e.stopPropagation();
      goBack();
    };

    // Tap on container (outside controls) reveals controls or switches photo
    if (container) {
      container.onclick = (e) => {
        if (e.target.closest('.controls-toolbar') || e.target.closest('#btn-back')) return;
        const rect = container.getBoundingClientRect();
        const clickX = e.clientX - rect.left;
        if (clickX < rect.width * 0.3) {
          this.prevPhoto();
        } else if (clickX > rect.width * 0.7) {
          this.nextPhoto();
        } else {
          // Center tap toggles controls visibility
          const ctrl = root.getElementById('controls');
          if (ctrl) {
            ctrl.style.opacity = ctrl.style.opacity === '1' ? '0' : '1';
          }
        }
      };
    }

    // Upload photo
    if (btnUpload && fileInput) {
      btnUpload.onclick = (e) => {
        e.stopPropagation();
        fileInput.click();
      };

      fileInput.onchange = (e) => {
        const files = Array.from(e.target.files || []);
        files.forEach(file => {
          if (!file.type.startsWith('image/')) return;
          const reader = new FileReader();
          reader.onload = (ev) => {
            const dataUrl = ev.target.result;
            this.photos.unshift(dataUrl);
            try {
              localStorage.setItem('kiosk_family_photos', JSON.stringify(this.photos.slice(0, 30)));
            } catch (err) {}
            this.currentIndex = 0;
            this.transitionToPhoto();
          };
          reader.readAsDataURL(file);
        });
      };
    }

    // Controls
    if (btnPrev) btnPrev.onclick = (e) => {
      e.stopPropagation();
      this.prevPhoto();
    };

    if (btnNext) btnNext.onclick = (e) => {
      e.stopPropagation();
      this.nextPhoto();
    };

    if (btnPlayPause) btnPlayPause.onclick = (e) => {
      e.stopPropagation();
      this.isPaused = !this.isPaused;
      btnPlayPause.textContent = this.isPaused ? '▶️' : '⏸️';
      if (this.isPaused) {
        if (this.timer) clearInterval(this.timer);
      } else {
        this.startSlideshow();
      }
    };
  }

  getCardSize() {
    return 8;
  }
}

if (!customElements.get('family-photo-card')) {
  customElements.define('family-photo-card', FamilyPhotoCard);
  console.log('✓ FamilyPhotoCard registered as <family-photo-card>');
}

window.customCards = window.customCards || [];
window.customCards.push({
  type: 'family-photo-card',
  name: 'Family Photo Display',
  description: 'Digital photo frame with clock, weather, and ambient transitions for family kiosks.',
  preview: true
});
