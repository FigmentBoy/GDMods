#customizable-kind of
CXX=gcc
OUTPUT=main.dylib

# no touch

LDFLAGS=-static-libstdc++
INCL=Cacao/include Cacao/include/cocos2dx Cacao/include/cocos2dx/include Cacao/include/cocos2dx/kazmath/include Cacao/include/cocos2dx/platform/mac Cacao/include/cocos2dx/platform/third_party/mac Cacao/include/cocos2dx/platform/third_party/mac/OGLES Cacao/include/cocos2dext Cacao/include/cocos2dx/custom/Sprites/CCMenuItemSpriteExtra
CXX_INCL=$(INCL:%=-I%)

CXX_FLAGS=-std=c++11 -DCC_TARGET_OS_MAC -lGDML -lCacao -LCacao/static -dynamiclib -o dist/$(OUTPUT) -lSystem -lstdc++ -static -g -mmacosx-version-min=10.7 -isysroot /Users/jakrillis/projects/builds/MacOSX-SDKS/MacOSX10.7.sdk


main: dist
	@echo "Building project..."
	@$(CXX) $(CXX_INCL) $(CXX_FLAGS) $(CXX_EXTRA) main.cpp
	@echo "Finished"
dist:
	mkdir dist
clean: 
	-@rm -rf dist 2>/dev/null || true
inject:
	sudo osxinj "Geometry Dash" dist/main.dylib