// SeeedJiggler firmware for Seeeduino XIAO (SAMD21): USB HID mouse (+ keyboard) and a CDC serial
// command port, with a watchdog that jiggles by itself if the host service goes quiet.
//
// Serial protocol (115200, one command per line, newline-terminated):
//   H                 heartbeat (feeds the watchdog; no reply)
//   ?                 status: "SEEEDJIGGLER 1 fb=<0|1> age=<ms> hb=<n> mv=<n>"  (does NOT feed the watchdog)
//   M <dx> <dy>       move mouse relatively (any size, chunked)             -> "OK"
//   anything else     -> "ERR"
//   T <text>          type text                                             -> "OK"   (full build only)
//   K <combo>         key combo, e.g. ctrl+c, cmd+space, enter, f5          -> "OK"   (full build only)
//   S <n>             scroll wheel (+up / -down)                            -> "OK"   (full build only)
//   C|D|U <l|r|m>     click / press / release                               -> "OK"   (full build only)
//
// Jiggler-only build (mouse movement only; no keyboard, no typing/click commands):
//   arduino-cli compile --fqbn Seeeduino:samd:seeed_XIAO_m0 \
//     --build-property "compiler.cpp.extra_flags=-DJIGGLER_ONLY=1" firmware/SeeedJiggler

#ifndef JIGGLER_ONLY
#define JIGGLER_ONLY 0
#endif

#if !JIGGLER_ONLY
#include <Keyboard.h>
#endif
#include <Mouse.h>

static const char *ID_STRING = "SEEEDJIGGLER";
static const int PROTOCOL_VERSION = 1;

// Watchdog: any command except '?' (the Mac service sends "H" every 5 s) counts as a heartbeat.
// No heartbeat for HB_TIMEOUT => service is down => the board jiggles by itself every FALLBACK_EVERY.
// All timers use unsigned subtraction so they stay correct across the 49.7-day millis() rollover.
static const unsigned long HB_TIMEOUT = 30000UL, FALLBACK_EVERY = 45000UL, LED_FLASH_MS = 80UL;

String line;
unsigned long lastCmd = 0, lastFallback = 0;
unsigned long txStart = 0, rxStart = 0;
bool txOn = false, rxOn = false;
bool fallback = false;
unsigned long hbCount = 0, mvCount = 0;

void flashTx() { digitalWrite(PIN_LED_TXL, LOW); txStart = millis(); txOn = true; }
void flashRx() { digitalWrite(PIN_LED_RXL, LOW); rxStart = millis(); rxOn = true; }

#if !JIGGLER_ONLY
uint8_t keyFor(String t) {
  t.toLowerCase();
  if (t == "ctrl") return KEY_LEFT_CTRL;
  if (t == "shift") return KEY_LEFT_SHIFT;
  if (t == "alt" || t == "opt") return KEY_LEFT_ALT;
  if (t == "cmd" || t == "gui" || t == "win") return KEY_LEFT_GUI;
  if (t == "enter" || t == "return") return KEY_RETURN;
  if (t == "esc") return KEY_ESC;
  if (t == "tab") return KEY_TAB;
  if (t == "backspace") return KEY_BACKSPACE;
  if (t == "delete") return KEY_DELETE;
  if (t == "space") return ' ';
  if (t == "up") return KEY_UP_ARROW;
  if (t == "down") return KEY_DOWN_ARROW;
  if (t == "left") return KEY_LEFT_ARROW;
  if (t == "right") return KEY_RIGHT_ARROW;
  if (t == "home") return KEY_HOME;
  if (t == "end") return KEY_END;
  if (t == "pageup") return KEY_PAGE_UP;
  if (t == "pagedown") return KEY_PAGE_DOWN;
  if (t.length() > 1 && t[0] == 'f') {
    int n = t.substring(1).toInt();
    if (n >= 1 && n <= 12) return KEY_F1 + n - 1;
  }
  if (t.length() == 1) return t[0];
  return 0;
}
char btn(String s) { s.toLowerCase(); return s == "r" ? MOUSE_RIGHT : s == "m" ? MOUSE_MIDDLE : MOUSE_LEFT; }
#endif

void handle(String l) {
  l.trim();
  if (l.length() < 1) return;
  char c = l[0];

  if (c == '?') {  // status query: does not touch lastCmd, so it can never mask a dead service
    Serial.print(ID_STRING); Serial.print(' '); Serial.print(PROTOCOL_VERSION);
    Serial.print(" fb="); Serial.print(fallback ? 1 : 0);
    Serial.print(" age="); Serial.print(millis() - lastCmd);
    Serial.print(" hb="); Serial.print(hbCount);
    Serial.print(" mv="); Serial.println(mvCount);
    return;
  }

  lastCmd = millis();
  if (c == 'H') { hbCount++; return; }  // heartbeat: no action, no reply

  String a = l.length() > 2 ? l.substring(2) : "";
  if (c == 'M') {
    flashTx();
    mvCount++;
    int sp = a.indexOf(' ');
    int dx = a.substring(0, sp).toInt(), dy = a.substring(sp + 1).toInt();
    while (dx || dy) {
      int sx = constrain(dx, -127, 127), sy = constrain(dy, -127, 127);
      Mouse.move(sx, sy, 0);
      dx -= sx; dy -= sy;
      delay(2);
    }
  }
#if !JIGGLER_ONLY
  else if (c == 'T') { Keyboard.print(a); flashRx(); }
  else if (c == 'K') {
    int s = 0;
    while (true) {
      int p = a.indexOf('+', s);
      String tok = p < 0 ? a.substring(s) : a.substring(s, p);
      uint8_t k = keyFor(tok);
      if (k) Keyboard.press(k);
      if (p < 0) break;
      s = p + 1;
    }
    delay(30);
    Keyboard.releaseAll();
    flashRx();
  }
  else if (c == 'S') { Mouse.move(0, 0, a.toInt()); }
  else if (c == 'C') { Mouse.click(btn(a)); flashTx(); }
  else if (c == 'D') { Mouse.press(btn(a)); }
  else if (c == 'U') { Mouse.release(btn(a)); }
#endif
  else { Serial.println("ERR"); return; }  // unknown command (or one compiled out of the jiggler-only build)
  Serial.println("OK");
}

void setup() {
  Serial.begin(115200);
  pinMode(LED_BUILTIN, OUTPUT); pinMode(PIN_LED_TXL, OUTPUT); pinMode(PIN_LED_RXL, OUTPUT);
  digitalWrite(LED_BUILTIN, HIGH); digitalWrite(PIN_LED_TXL, HIGH); digitalWrite(PIN_LED_RXL, HIGH);
#if !JIGGLER_ONLY
  Keyboard.begin();
#endif
  Mouse.begin();
}

void loop() {
  unsigned long now = millis();
  bool up = USBDevice.configured();
  fallback = up && (now - lastCmd > HB_TIMEOUT);
  if (!up) digitalWrite(LED_BUILTIN, HIGH);
  else if (fallback) digitalWrite(LED_BUILTIN, (now / 500) % 2 ? LOW : HIGH);  // blinking = service silent, self-jiggling
  else digitalWrite(LED_BUILTIN, LOW);                                          // solid = host + service OK
  if (fallback && now - lastFallback > FALLBACK_EVERY) {
    lastFallback = now;
    Mouse.move(8, 0, 0); delay(20); Mouse.move(-8, 0, 0); flashTx();
  }
  // Fresh millis() here, not the cached `now`: the fallback block above (delay + flashTx) may have just
  // set txStart to a time later than `now`, which would underflow the subtraction and turn the LED off at once.
  if (txOn && millis() - txStart > LED_FLASH_MS) { digitalWrite(PIN_LED_TXL, HIGH); txOn = false; }
  if (rxOn && millis() - rxStart > LED_FLASH_MS) { digitalWrite(PIN_LED_RXL, HIGH); rxOn = false; }
  while (Serial.available()) {
    char ch = Serial.read();
    if (ch == '\n') { handle(line); line = ""; }
    else if (ch != '\r' && line.length() < 400) line += ch;
  }
}
