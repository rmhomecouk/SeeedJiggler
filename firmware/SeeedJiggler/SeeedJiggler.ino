// SeeedJiggler firmware for Seeeduino XIAO (SAMD21): USB HID mouse (no keyboard) and a CDC serial
// command port. The board never moves the mouse on its own: the host app decides everything.
//
// Serial protocol (115200, one command per line, newline-terminated):
//   H                 heartbeat (only drives the LED; no reply)
//   ?                 status: "SEEEDJIGGLER 2 app=<0|1> age=<ms> hb=<n> mv=<n>"  (does not count as a heartbeat)
//   M <dx> <dy>       move mouse relatively (any size, chunked)             -> "OK"
//   anything else     -> "ERR"

#include <Mouse.h>

static const char *ID_STRING = "SEEEDJIGGLER";
static const int PROTOCOL_VERSION = 2;

// App presence: any command except '?' (the Mac app sends "H" every 5 s) counts as a heartbeat. With no heartbeat for
// HB_TIMEOUT the yellow LED blinks so you can see the app is gone. The board does NOT move the mouse on its own.
// All timers use unsigned subtraction so they stay correct across the 49.7-day millis() rollover.
static const unsigned long HB_TIMEOUT = 30000UL, LED_FLASH_MS = 80UL;

String line;
unsigned long lastCmd = 0;
unsigned long txStart = 0;
bool txOn = false;
bool appSilent = false, heardApp = false;  // heardApp: a heartbeat has arrived since boot
unsigned long hbCount = 0, mvCount = 0;

void flashTx() { digitalWrite(PIN_LED_TXL, LOW); txStart = millis(); txOn = true; }

void handle(String l) {
  l.trim();
  if (l.length() < 1) return;
  char c = l[0];

  if (c == '?') {  // status query: does not touch lastCmd, so it can never mask a dead host app
    Serial.print(ID_STRING); Serial.print(' '); Serial.print(PROTOCOL_VERSION);
    Serial.print(" app="); Serial.print(appSilent ? 0 : 1);
    Serial.print(" age="); Serial.print(millis() - lastCmd);
    Serial.print(" hb="); Serial.print(hbCount);
    Serial.print(" mv="); Serial.println(mvCount);
    return;
  }

  lastCmd = millis();
  heardApp = true;
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
  else { Serial.println("ERR"); return; }  // unknown command
  Serial.println("OK");
}

void setup() {
  Serial.begin(115200);
  pinMode(LED_BUILTIN, OUTPUT); pinMode(PIN_LED_TXL, OUTPUT); pinMode(PIN_LED_RXL, OUTPUT);
  digitalWrite(LED_BUILTIN, HIGH); digitalWrite(PIN_LED_TXL, HIGH); digitalWrite(PIN_LED_RXL, HIGH);
  Mouse.begin();
}

void loop() {
  unsigned long now = millis();
  bool up = USBDevice.configured();
  appSilent = up && (!heardApp || now - lastCmd > HB_TIMEOUT);
  if (!up) digitalWrite(LED_BUILTIN, HIGH);
  else if (appSilent) digitalWrite(LED_BUILTIN, (now / 500) % 2 ? LOW : HIGH);  // blinking = app silent (board idle)
  else digitalWrite(LED_BUILTIN, LOW);                                          // solid = host + app OK
  // Fresh millis() here, not the cached `now`: a command handled earlier in loop() may have set txStart later than `now`.
  if (txOn && millis() - txStart > LED_FLASH_MS) { digitalWrite(PIN_LED_TXL, HIGH); txOn = false; }
  while (Serial.available()) {
    char ch = Serial.read();
    if (ch == '\n') { handle(line); line = ""; }
    else if (ch != '\r' && line.length() < 400) line += ch;
  }
}
