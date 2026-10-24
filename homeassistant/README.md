# 🏠 Home Assistant Integration & Custom Lovelace Card

This directory contains resources to integrate your **Raspberry Pi Kiosk** deeply into **Home Assistant**:

1. **`kiosk-card.js`**: A custom Lovelace card to monitor and control your kiosk screen power, brightness, reload, reboot, and active URL directly from your Home Assistant dashboard.
2. **Automations & Blueprints**:
   * `automations/kiosk_motion_screen.yaml`: Motion-activated screen wake and sleep.
   * `automations/kiosk_night_sleep.yaml`: Scheduled night sleep and morning wake.

---

## 📦 How to Install the Custom Lovelace Card

### Step 1: Copy `kiosk-card.js` to Home Assistant
Copy `kiosk-card.js` into your Home Assistant `/config/www/` folder.  
*(If the `www` folder doesn't exist, create it).*

### Step 2: Add Resource in Home Assistant
1. In Home Assistant, go to **Settings** &rarr; **Dashboards**.
2. Click the 3 dots in the top right &rarr; **Resources**.
3. Click **Add Resource**:
   * **URL:** `/local/kiosk-card.js`
   * **Resource Type:** `JavaScript Module`
4. Click **Create**.

### Step 3: Add the Card to Your Dashboard
Edit your dashboard and add a **Manual Card** with:

```yaml
type: custom:rpi-kiosk-card
title: Wall Kiosk Display
switch_entity: switch.rpi_kiosk_screen
brightness_entity: number.rpi_kiosk_brightness
temperature_entity: sensor.rpi_kiosk_cpu_temperature
reload_button: button.rpi_kiosk_reload
reboot_button: button.rpi_kiosk_reboot
```

---

## ⚡ Automations / Blueprints

To install either blueprint:
1. Copy the YAML file from `homeassistant/automations/` to your Home Assistant `/config/blueprints/automation/` folder.
2. Go to **Settings** &rarr; **Automations & Scenes** &rarr; **Blueprints**.
3. Create an automation using the blueprint, select your motion sensor and the `switch.rpi_kiosk_screen` entity!
