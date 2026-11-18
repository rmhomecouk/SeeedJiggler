#include <Keyboard.h>
#include <Mouse.h>

// Line protocol over USB serial (CDC), one command per line:
//   T <text>          type text
//   K <combo>         key combo, e.g. ctrl+c, cmd+space, enter, f5
//   M <dx> <dy>       move mouse relatively (any size, chunked)
//   S <n>             scroll wheel (+up / -down)
//   C <l|r|m>         click        D <l|r|m> press   U <l|r|m> release
String line;
unsigned long txOff = 0, rxOff = 0;
// Watchdog: any command (the Mac service sends "H" every 5s) counts as a heartbeat.
// No heartbeat for HB_TIMEOUT => service is down => board jiggles by itself.
const unsigned long HB_TIMEOUT = 30000, FALLBACK_EVERY = 45000;
unsigned long lastCmd = 0, lastFallback = 0;
bool fallback = false;
void flashTx() { digitalWrite(PIN_LED_TXL, LOW); txOff = millis() + 80; }
void flashRx() { digitalWrite(PIN_LED_RXL, LOW); rxOff = millis() + 80; }


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

void handle(String l) {
  l.trim();
  if (l.length() < 1) return;
  lastCmd = millis();
  char c = l[0];
  String a = l.length() > 2 ? l.substring(2) : "";
  if (c == 'T') { Keyboard.print(a); flashRx(); }
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
  else if (c == 'M') {
    flashTx();
    int sp = a.indexOf(' ');
    int dx = a.substring(0, sp).toInt(), dy = a.substring(sp + 1).toInt();
    while (dx || dy) {
      int sx = constrain(dx, -127, 127), sy = constrain(dy, -127, 127);
      Mouse.move(sx, sy, 0);
      dx -= sx; dy -= sy;
      delay(2);
    }
  }
  else if (c == 'S') { Mouse.move(0, 0, a.toInt()); }
  else if (c == 'C') { Mouse.click(btn(a)); flashTx(); }
  else if (c == 'D') { Mouse.press(btn(a)); }
  else if (c == 'U') { Mouse.release(btn(a)); }
  // 'H' = heartbeat, no action
  Serial.println("OK");
}

void setup() {
  Serial.begin(115200);
  pinMode(LED_BUILTIN, OUTPUT); pinMode(PIN_LED_TXL, OUTPUT); pinMode(PIN_LED_RXL, OUTPUT);
  digitalWrite(LED_BUILTIN, HIGH); digitalWrite(PIN_LED_TXL, HIGH); digitalWrite(PIN_LED_RXL, HIGH);
  Keyboard.begin();
  Mouse.begin();
}
void loop() {
  bool up = USBDevice.configured();
  fallback = up && (millis() - lastCmd > HB_TIMEOUT);
  if (!up) digitalWrite(LED_BUILTIN, HIGH);
  else if (fallback) digitalWrite(LED_BUILTIN, (millis() / 500) % 2 ? LOW : HIGH);  // blinking = service down, self-jiggling
  else digitalWrite(LED_BUILTIN, LOW);                                              // solid = host + service OK
  if (fallback && millis() - lastFallback > FALLBACK_EVERY) {
    lastFallback = millis();
    Mouse.move(8, 0, 0); delay(20); Mouse.move(-8, 0, 0); flashTx();
  }
  if (txOff && millis() > txOff) { digitalWrite(PIN_LED_TXL, HIGH); txOff = 0; }
  if (rxOff && millis() > rxOff) { digitalWrite(PIN_LED_RXL, HIGH); rxOff = 0; }
  while (Serial.available()) {
    char ch = Serial.read();
    if (ch == '\n') { handle(line); line = ""; }
    else if (ch != '\r' && line.length() < 400) line += ch;
  }
}
