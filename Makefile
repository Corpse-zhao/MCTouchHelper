TARGET := iphone:clang:latest:14.0
ARCHS = arm64 arm64e
INSTALL_TARGET_PROCESSES = SpringBoard

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = MCTouchHelper
MCTouchHelper_FILES = Tweak.x
MCTouchHelper_CFLAGS = -fobjc-arc
MCTouchHelper_FRAMEWORKS = UIKit Foundation

include $(THEOS_MAKE_PATH)/tweak.mk
