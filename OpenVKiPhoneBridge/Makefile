THEOS_PACKAGE_SCHEME = rootless
ARCHS = arm64
TARGET = iphone:clang:latest:8.0

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = OpenVKiPhoneBridge

OpenVKiPhoneBridge_FILES = ../OpenVKiPadBridge/Tweak.xm
OpenVKiPhoneBridge_CFLAGS = -fobjc-arc
OpenVKiPhoneBridge_FRAMEWORKS = Foundation Security AVFoundation

include $(THEOS_MAKE_PATH)/tweak.mk

