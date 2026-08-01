TARGET := iphone:clang:latest:15.0
ARCHS = arm64 arm64e
INSTALL_TARGET_PROCESSES = Aweme

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = YukiPreventDelete

YukiPreventDelete_FILES = Tweak.xm
YukiPreventDelete_CFLAGS = -fobjc-arc -w
YukiPreventDelete_FRAMEWORKS = Foundation UIKit
DYYY_LOGOS_DEFAULT_GENERATOR = internal

export THEOS_STRICT_LOGOS = 0
export ERROR_ON_WARNINGS = 0
export LOGOS_DEFAULT_GENERATOR = internal

include $(THEOS_MAKE_PATH)/tweak.mk
