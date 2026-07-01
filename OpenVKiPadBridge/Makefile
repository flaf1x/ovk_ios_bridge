ARCHS = armv7 arm64
TARGET = iphone:clang:latest:7.0

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = OpenVKiPadBridge

OpenVKiPadBridge_FILES = Tweak.xm
OpenVKiPadBridge_CFLAGS = -fobjc-arc
OpenVKiPadBridge_FRAMEWORKS = Foundation Security AVFoundation UIKit QuartzCore

include $(THEOS_MAKE_PATH)/tweak.mk

after-install::
	install.exec "killall -9 VkHdAppstore 2>/dev/null || true"
