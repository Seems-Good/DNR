# DNR (DoNotRelease)
Simple reminder addon to not release on death with multiple 'guard' options that physically prevent player from pressing release!

<img width="687" height="161" alt="image" src="https://github.com/user-attachments/assets/775eef63-fa3d-4d3a-9920-3e13fb1e9464" />

### **Features:**
- After dying in a instance group display in large text "DO NOT RELEASE" (Default, change later!)
- Configure position and customize color and text to display on screen.
- Inspired by similar weakauras

### Optional Features:
**Release Guard**
Release Guard allows 3 options to further prevent the player from pressing release spirit.
- 5-Second Timer adds a short countdown before the option to release appears. (_**DEFAULT as of v1.3.0**_) 
- 4-Digit Code: generated a random 4 digit code to verify before seeing release UI. (captcha style)
- TOTP/2FA: ([RFC 6238](https://www.rfc-editor.org/rfc/rfc6238)) Compatible with your fav. Authenticator app. (for the serial releasers)
- Off: ONLY display "Do Not Release" after dying

### Usage:
**Command Usage:**
- `/dnr` - Prints available commands.
- `/dnr config` - Opens a menu to change position text on screen and color of text.

**Debug Commands:**
- `/dnr test` - Display the text outside of death (testing)
- `/dnr hide` - Hide the text on screen after using `/dnr test`
