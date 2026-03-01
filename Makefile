TARGET := iphone:clang:latest:14.0


include $(THEOS)/makefiles/common.mk

TWEAK_NAME = SimpleAutoClicker
ZSFakeTouch_DIR = ZSFakeTouch/ZSFakeTouchDome/ZSFakeTouch
ZSFakeTouch_ADDITION = ZSFakeTouch/ZSFakeTouchDome/ZSFakeTouch/addition
ZSFakeTouch_VISUALIZER = ZSFakeTouch/ZSFakeTouchDome/ZSFakeTouch/Visualizer

SimpleAutoClicker_FILES = Tweak.x ${ZSFakeTouch_DIR}/ZSFakeTouch.m ${ZSFakeTouch_ADDITION}/UIApplication-KIFAdditions.m ${ZSFakeTouch_ADDITION}/UITouch-KIFAdditions.m ${ZSFakeTouch_ADDITION}/UIEvent+KIFAdditions.m ${ZSFakeTouch_ADDITION}/IOHIDEvent+KIF.m 
# 遍历${ZSFakeTouch_VISUALIZER}添加到编译
SimpleAutoClicker_FILES += $(foreach file,$(wildcard ${ZSFakeTouch_VISUALIZER}/*.m),$(file))
SimpleAutoClicker_CFLAGS = -fobjc-arc -ObjC -I ${ZSFakeTouch_ADDITION} -I ${ZSFakeTouch_VISUALIZER}
SimpleAutoClicker_PRIVATE_FRAMEWORKS = IOKit

include $(THEOS_MAKE_PATH)/tweak.mk
