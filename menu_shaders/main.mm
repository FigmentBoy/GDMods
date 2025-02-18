#include <fmod.hpp>
#include <Cacao>
#include <fstream>
#include <unistd.h>
#include <algorithm>
#include <CoreGraphics/CoreGraphics.h>
using namespace cocos2d;

#define STRINGIFY(...) #__VA_ARGS__

extern "C" CGPoint getMouse();
static const auto menuShadersKey = "menu-shader-enabled";
bool g_enabled = false;

class MyShaderProgram : public CCGLProgram {
public:
    std::string getFragShaderLog() {
        GLint length, written;
        glGetShaderiv(this->m_uFragShader, GL_INFO_LOG_LENGTH, &length);
        if (length <= 0) return "";
        auto stuff = new char[length + 1];
        glGetShaderInfoLog(this->m_uFragShader, length, &written, stuff);
        std::string result(stuff);
        delete[] stuff;
        return result;
    }
};

class ShaderNode : public CCNode {
    GLuint m_uniformResolution,
        m_uniformTime,
        m_uniformMouse,
        m_uniformPulse1,
        m_uniformPulse2,
        m_uniformPulse3,
        m_uniformFft;
    float m_time;
    FMOD::DSP* m_fftDsp = nullptr;
    static constexpr int FFT_SPECTRUM_SIZE = 1024;
    // gd cuts frequencies higher than ~16kHz, so we should too (the "140/512" part)
    // we also remove the right half (by multiplying by 2), because it's a mirrored version of the left half, so we don't need that
    // (and fmod actually removes it completely, so it's always all zeros anyway)
    // (there are actually 513 empty bins instead of 512 but the last one gets cut off by the "140/512" part)
    // i know, this is weird af
    static constexpr int FFT_ACTUAL_SPECTRUM_SIZE = FFT_SPECTRUM_SIZE - (FFT_SPECTRUM_SIZE * 140 / 512);
    static constexpr int FFT_WINDOW_SIZE = FFT_SPECTRUM_SIZE * 2;
    static constexpr float FFT_UPDATE_FREQUENCY = 20.f;
    float m_spectrum[FFT_ACTUAL_SPECTRUM_SIZE];
    float m_oldSpectrum[FFT_ACTUAL_SPECTRUM_SIZE];
    float m_newSpectrum[FFT_ACTUAL_SPECTRUM_SIZE];
    float m_spectrumUpdateAccumulator;
    CCArray* m_shaderSprites;
public:
    bool init(const GLchar* vert, const std::string& frag) {
        auto shader = new CCGLProgram;
        static bool hasPatched = false;

        if (!shader->initWithVertexShaderByteArray(vert, frag.c_str())) {
            const auto error = reinterpret_cast<MyShaderProgram*>(shader)->getFragShaderLog();
            FLAlertLayer::create("menu-shaders failed to load shaders", error, "Ok")->show();
            return false;
        }
        m_shaderSprites = CCArray::create();
        m_shaderSprites->retain();
        if (frag.size() > 3 && frag.compare(0, 3, "//@") == 0) {
            std::istringstream stream(frag);
            stream.seekg(4);
            std::string line;
            std::getline(stream, line);
            std::string::size_type pos = line.find(',');
            const auto addSprite = [&](const std::string& name) {
                std::cout << "loading sprite \"" << name << "\"" << std::endl;
                auto sprite = CCSprite::create(name.c_str());
                sprite->retain();
                std::cout << sprite << std::endl;
                m_shaderSprites->addObject(sprite);
            };
            int i = 0;
            while (pos = line.find(','), pos != std::string::npos) {
                auto me = line.substr(0, pos);
                line = line.substr(pos + 1);
                addSprite(me);
            }
            if (line.size()) addSprite(line);
        }

        auto engine = FMODAudioEngine::sharedEngine();
        engine->m_pSystem->createDSPByType(FMOD_DSP_TYPE_FFT, &m_fftDsp);
        engine->m_pGlobalChannel->addDSP(1, m_fftDsp);
        m_fftDsp->setParameterInt(FMOD_DSP_FFT_WINDOWTYPE, FMOD_DSP_FFT_WINDOW_HAMMING);
        m_fftDsp->setParameterInt(FMOD_DSP_FFT_WINDOWSIZE, FFT_WINDOW_SIZE);
        m_fftDsp->setActive(true);

        std::memset(m_spectrum, 0, FFT_ACTUAL_SPECTRUM_SIZE * sizeof(float));
        std::memset(m_oldSpectrum, 0, FFT_ACTUAL_SPECTRUM_SIZE * sizeof(float));
        std::memset(m_newSpectrum, 0, FFT_ACTUAL_SPECTRUM_SIZE * sizeof(float));

        shader->addAttribute(kCCAttributeNamePosition, kCCVertexAttrib_Position);
        shader->addAttribute(kCCAttributeNameTexCoord, kCCVertexAttrib_TexCoords);
        shader->link();

        shader->updateUniforms();

        m_uniformResolution = glGetUniformLocation(shader->getProgram(), "resolution");
        m_uniformTime = glGetUniformLocation(shader->getProgram(), "time");
        m_uniformMouse = glGetUniformLocation(shader->getProgram(), "mouse");
        m_uniformPulse1 = glGetUniformLocation(shader->getProgram(), "pulse1");
        m_uniformPulse2 = glGetUniformLocation(shader->getProgram(), "pulse2");
        m_uniformPulse3 = glGetUniformLocation(shader->getProgram(), "pulse3");
        m_uniformFft = glGetUniformLocation(shader->getProgram(), "fft");

        for (size_t i = 0; i < m_shaderSprites->count(); ++i) {
            auto uniform = glGetUniformLocation(shader->getProgram(), ("sprite" + std::to_string(i)).c_str());
            glUniform1i(uniform, i);
            // std::cout << "setting some uniform" << std::endl;
            // auto sprite = reinterpret_cast<CCSprite*>(m_shaderSprites->objectAtIndex(i));
            // sprite->setScale(0.3f);
            // ccGLBindTexture2DN(sprite->getTexture()->getName(), i);
        }

        this->setShaderProgram(shader);

        m_time = 0.f;
        auto size = CCDirector::sharedDirector()->getWinSize();

        shader->release();

        this->scheduleUpdate();

        setContentSize(size);
        setAnchorPoint({0.5f, 0.5f});
        return true;
    }

    ~ShaderNode() {
        if (m_fftDsp) {
            FMODAudioEngine::sharedEngine()->m_pGlobalChannel->removeDSP(m_fftDsp);
        }
    }

    virtual void update(float dt) {
        m_time += dt;
        m_spectrumUpdateAccumulator += dt;

        const float speed = 1.f / FFT_UPDATE_FREQUENCY;
        if (m_spectrumUpdateAccumulator >= speed) {
            auto engine = FMODAudioEngine::sharedEngine();
            if (m_fftDsp) {
                FMOD_DSP_PARAMETER_FFT* data;
                unsigned int length;
                m_fftDsp->getParameterData(FMOD_DSP_FFT_SPECTRUMDATA, (void**)&data, &length, nullptr, 0);
                if (length) {
                    for (size_t i = 0; i < std::min(data->length, FFT_ACTUAL_SPECTRUM_SIZE); i++) {
                        m_oldSpectrum[i] = m_newSpectrum[i];
                        m_newSpectrum[i] = 0.f;
                        int n = std::min(data->numchannels, 2);
                        for (size_t j = 0; j < n; ++j) {
                            m_newSpectrum[i] += data->spectrum[j][i];
                        }
                        m_newSpectrum[i] /= float(n);
                    }
                }
            }
            m_spectrumUpdateAccumulator = 0.f;
        }
        float t = m_spectrumUpdateAccumulator * FFT_UPDATE_FREQUENCY;
        for (int i = 0; i < FFT_ACTUAL_SPECTRUM_SIZE; i++) {
            m_spectrum[i] = (1.f - t) * m_oldSpectrum[i] + t * m_newSpectrum[i];
        }
    }
    virtual void draw() {
        CC_NODE_DRAW_SETUP();

        auto glv = CCDirector::sharedDirector()->getOpenGLView();
        auto size = CCDirector::sharedDirector()->getWinSize();
        auto frSize = glv->getFrameSize();
        float w = frSize.width, h = frSize.height;
        GLfloat vertices[12] = {0,0, w,0, w,h, 0,0, 0,h, w,h};

        getShaderProgram()->setUniformLocationWith2f(m_uniformResolution, w, h);
        CGPoint mousePos = getMouse();
        getShaderProgram()->setUniformLocationWith2f(m_uniformMouse, mousePos.x, h - mousePos.y);

        for (size_t i = 0; i < m_shaderSprites->count(); ++i) {
            auto sprite = dynamic_cast<CCSprite*>(m_shaderSprites->objectAtIndex(i));
            if (sprite) {
                sprite->setScale(0.3f);
                ccGLBindTexture2DN(i, sprite->getTexture()->getName());
            }
        }

        glUniform1f(m_uniformTime, m_time);

        // thx adaf for telling me where these are
        auto engine = FMODAudioEngine::sharedEngine();
        glUniform1f(m_uniformPulse1, engine->m_fPulse1);
        glUniform1f(m_uniformPulse2, engine->m_fPulse2);
        glUniform1f(m_uniformPulse3, engine->m_fPulse3);

        glUniform1fv(m_uniformFft, FFT_ACTUAL_SPECTRUM_SIZE, m_spectrum);

        ccGLEnableVertexAttribs(kCCVertexAttribFlag_Position);

        glVertexAttribPointer(kCCVertexAttrib_Position, 2, GL_FLOAT, GL_FALSE, 0, vertices);

        glDrawArrays(GL_TRIANGLES, 0, 6);
        
        // CC_INCREMENT_GL_DRAWS(1); // this crashes :c
    }
    static auto create(const GLchar* vert, const std::string& frag) {
        auto node = new ShaderNode;
        if (node->init(vert, frag)) {
            node->autorelease();
        } else {
            CC_SAFE_DELETE(node);
        }
        return node;
    }
};


class $redirect(MenuLayer) {
	bool init() {
		g_enabled = GameManager::sharedState()->getGameVariable(menuShadersKey);
		static bool hasPatched = false;
		if (g_enabled && !hasPatched) {
		    // huge thanks to adaf for this!
		    // im doing the patch here instead of the dll entry thread because
		    // that could cause a crash as its in a different thread
		    //patch(cast<void*>(gd::base + 0x23b56), {0x90, 0x90, 0x90, 0x90, 0x90, 0x90});
		    hasPatched = true;
		}

		if (!$MenuLayer::init()) return false;
		if (!g_enabled) return true;

		// hm yes very safe, although i cant think of a better way
		auto gameLayer = dynamic_cast<CCLayer*>(getChildren()->objectAtIndex(0));
		if (gameLayer != nullptr) {
		    gameLayer->removeFromParentAndCleanup(true);
		    gameLayer = nullptr;
		}
		const auto shaderPath = CCFileUtils::sharedFileUtils()->fullPathForFilename("menu-shader.fsh", false);
		std::string shaderSource;
		// yes im using std::filesystem just for this
		// CCFileUtils::isFileExist is really weird and broken
		if (access( std::string(shaderPath).c_str(), F_OK ) == 0) {
		    std::ifstream file;
		    file.open(shaderPath, std::ios::in);
		    // this is the best way i could find of reading an entire file
		    std::ostringstream sstr;
		    sstr << file.rdbuf();
		    shaderSource = sstr.str();
		    file.close();
		} else {
		    // default shader is a blue swirly pattern
		    // which i made some time ago in shadertoy
		    // https://www.shadertoy.com/view/wdG3Wh
		    shaderSource = STRINGIFY(
		        uniform vec2 resolution;
		        uniform float time;
		        uniform vec2 mouse; // not used here

		        vec2 hash(vec2 p) {
		            p = vec2(dot(p,vec2(127.1,311.7)), dot(p,vec2(269.5,183.3)));
		            return -1.0 + 2.0*fract(sin(p)*43758.5453123);
		        }

		        float noise(in vec2 p) {
		            const float K1 = 0.366025404; // (sqrt(3)-1)/2;
		            const float K2 = 0.211324865; // (3-sqrt(3))/6;

		            vec2  i = floor( p + (p.x+p.y)*K1 );
		            vec2  a = p - i + (i.x+i.y)*K2;
		            float m = step(a.y,a.x); 
		            vec2  o = vec2(m,1.0-m);
		            vec2  b = a - o + K2;
		            vec2  c = a - 1.0 + 2.0*K2;
		            vec3  h = max( 0.5-vec3(dot(a,a), dot(b,b), dot(c,c) ), 0.0 );
		            vec3  n = h*h*h*h*vec3( dot(a,hash(i+0.0)), dot(b,hash(i+o)), dot(c,hash(i+1.0)));
		            return dot(n, vec3(70.0));
		        }

		        void main() {
		            // mat wtf is this
		            vec2 uv = (gl_FragCoord.xy - 0.5*resolution.xy ) / resolution.y;
		
		            uv = vec2(noise(uv+time*0.1), noise(uv+10.));
		            float d = uv.x - uv.y;
		            d *= 20.;
		            d = sin(d);
		            d = d * 0.5 + 0.5;
		            d = 1.0 - d;
		            
		            d = smoothstep(0.1, 0.1, d);
		            
		            vec3 col = vec3(mix(vec3(0.1), vec3(0.2, 0.2, 0.6), d));

		            gl_FragColor = vec4(col,1.0);
		        }
		    );
		}
		/*
		Heres an extremely simple shader that just shows the uv,
		while also showing all available uniforms
		uniform vec2 resolution;
		uniform float time;
		uniform vec2 mouse;
		uniform float pulse1; // i recommend this one
		uniform float pulse2;
		uniform float pulse3;
		uniform float fft[744];
		void main() {
		    vec2 uv = gl_FragCoord.xy / resolution;
		    uv.x *= resolution.x / resolution.y; // optional: fix aspect ratio
		    gl_FragColor = vec4(uv, 0.0, 1.0);
		}
		*/

		auto shader = ShaderNode::create(STRINGIFY(
		    attribute vec4 a_position;

		    void main() {
		        gl_Position = CC_MVPMatrix * a_position;
		    }
		), shaderSource);

		if (shader == nullptr)
		    return true;

		shader->setZOrder(-10);
		addChild(shader);
		auto size = CCDirector::sharedDirector()->getWinSize();
		shader->setPosition(size / 2);
		return true;
	} 
};
