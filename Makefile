THEOS_PACKAGE_SCHEME = rootless

TARGET := iphone:clang:latest:15.0
INSTALL_TARGET_PROCESSES = Aweme

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = YukiPreventDelete

YukiPreventDelete_FILES = Tweak.xm
YukiPreventDelete_CFLAGS = -fobjc-arc
YukiPreventDelete_CCFLAGS = -std=c++17
YukiPreventDelete_FRAMEWORKS = Foundation UIKit
YukiPreventDelete_PRIVATE_FRAMEWORKS = AppSupport

include $(THEOS_MAKE_PATH)/tweak.mk

after-package::
	cp -r layout/ "$(THEOS_STAGING_DIR)/"
