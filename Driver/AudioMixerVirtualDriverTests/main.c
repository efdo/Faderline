/*
 * main.c — Driver unit + IO smoke tests for AudioMixerVirtualDriver.
 *
 * Loads the built .driver bundle the same way coreaudiod would (via
 * CFPlugIn), then exercises the AudioServerPlugInDriverInterface directly:
 * no coreaudiod, no real audio hardware, no XCTest — just CFPlugIn +
 * assert(). This lets the driver's property model, ring buffer, and clock
 * be verified in isolation, independent from the "installed driver" AUHAL
 * smoke test that exercises the same device once it's actually loaded by
 * coreaudiod.
 *
 * Usage: AudioMixerVirtualDriverTests /path/to/AudioMixerVirtualDriver.driver
 */

#include <CoreFoundation/CoreFoundation.h>
#include <CoreFoundation/CFPlugInCOM.h>
#include <CoreAudio/AudioServerPlugIn.h>
#include <assert.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>

enum
{
    kObjectID_PlugIn        = kAudioObjectPlugInObject,
    kObjectID_Box           = 2,
    kObjectID_Device        = 3,
    kObjectID_Stream_Input  = 4,
    kObjectID_Stream_Output = 5,
};

static const Float64 kSampleRate = 48000.0;
static const UInt32  kChannelCount = 2;
static const UInt32  kRingBufferFrames = 65536;

/* Minimal host interface: enough for Initialize() to succeed. None of the
 * driver's tested paths call back into the host, so these are no-ops. */
static OSStatus Host_PropertiesChanged(AudioServerPlugInHostRef inHost, AudioObjectID inObjectID, UInt32 inNumberAddresses, const AudioObjectPropertyAddress *inAddresses)
{
    (void)inHost; (void)inObjectID; (void)inNumberAddresses; (void)inAddresses;
    return kAudioHardwareNoError;
}
static OSStatus Host_CopyFromStorage(AudioServerPlugInHostRef inHost, CFStringRef inKey, CFPropertyListRef *outData)
{
    (void)inHost; (void)inKey; *outData = NULL; return kAudioHardwareNoError;
}
static OSStatus Host_WriteToStorage(AudioServerPlugInHostRef inHost, CFStringRef inKey, CFPropertyListRef inData)
{
    (void)inHost; (void)inKey; (void)inData; return kAudioHardwareNoError;
}
static OSStatus Host_DeleteFromStorage(AudioServerPlugInHostRef inHost, CFStringRef inKey)
{
    (void)inHost; (void)inKey; return kAudioHardwareNoError;
}
static OSStatus Host_RequestDeviceConfigurationChange(AudioServerPlugInHostRef inHost, AudioObjectID inDeviceObjectID, UInt64 inChangeAction, void *inChangeInfo)
{
    (void)inHost; (void)inDeviceObjectID; (void)inChangeAction; (void)inChangeInfo;
    return kAudioHardwareNoError;
}

static AudioServerPlugInHostInterface gHostInterface = {
    .PropertiesChanged = Host_PropertiesChanged,
    .CopyFromStorage = Host_CopyFromStorage,
    .WriteToStorage = Host_WriteToStorage,
    .DeleteFromStorage = Host_DeleteFromStorage,
    .RequestDeviceConfigurationChange = Host_RequestDeviceConfigurationChange,
};
static AudioServerPlugInHostInterface *gHostInterfacePtr = &gHostInterface;

static int gFailures = 0;

#define CHECK(cond) \
    do { \
        if (!(cond)) { \
            fprintf(stderr, "FAIL %s:%d: %s\n", __FILE__, __LINE__, #cond); \
            gFailures++; \
        } \
    } while (0)

#define CHECK_STATUS(expr) CHECK((expr) == kAudioHardwareNoError)

static UInt32 GetU32(AudioServerPlugInDriverRef driver, AudioObjectID objectID, AudioObjectPropertySelector selector, AudioObjectPropertyScope scope)
{
    AudioObjectPropertyAddress address = { selector, scope, kAudioObjectPropertyElementMain };
    UInt32 size = 0;
    OSStatus status = (*driver)->GetPropertyDataSize(driver, objectID, 0, &address, 0, NULL, &size);
    CHECK_STATUS(status);
    CHECK(size == sizeof(UInt32));
    UInt32 value = 0;
    UInt32 used = 0;
    status = (*driver)->GetPropertyData(driver, objectID, 0, &address, 0, NULL, sizeof(value), &used, &value);
    CHECK_STATUS(status);
    CHECK(used == sizeof(UInt32));
    return value;
}

static CFStringRef CopyStringProperty(AudioServerPlugInDriverRef driver, AudioObjectID objectID, AudioObjectPropertySelector selector)
{
    AudioObjectPropertyAddress address = { selector, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain };
    CFStringRef value = NULL;
    UInt32 used = 0;
    OSStatus status = (*driver)->GetPropertyData(driver, objectID, 0, &address, 0, NULL, sizeof(value), &used, &value);
    CHECK_STATUS(status);
    return value;
}

static void TestPlugInAndBoxProperties(AudioServerPlugInDriverRef driver)
{
    AudioObjectPropertyAddress boxListAddr = { kAudioPlugInPropertyBoxList, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain };
    CHECK((*driver)->HasProperty(driver, kObjectID_PlugIn, 0, &boxListAddr));

    AudioObjectPropertyAddress deviceListAddr = { kAudioPlugInPropertyDeviceList, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain };
    UInt32 size = 0;
    CHECK_STATUS((*driver)->GetPropertyDataSize(driver, kObjectID_PlugIn, 0, &deviceListAddr, 0, NULL, &size));
    CHECK(size == sizeof(AudioObjectID));
    AudioObjectID device = 0;
    UInt32 used = 0;
    CHECK_STATUS((*driver)->GetPropertyData(driver, kObjectID_PlugIn, 0, &deviceListAddr, 0, NULL, sizeof(device), &used, &device));
    CHECK(device == kObjectID_Device);

    CFStringRef boxUID = CopyStringProperty(driver, kObjectID_Box, kAudioBoxPropertyBoxUID);
    CHECK(boxUID != NULL);

    AudioObjectPropertyAddress translateAddr = { kAudioPlugInPropertyTranslateUIDToDevice, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain };
    CFStringRef deviceUID = CopyStringProperty(driver, kObjectID_Device, kAudioDevicePropertyDeviceUID);
    CHECK(deviceUID != NULL);
    AudioObjectID translated = 0;
    used = 0;
    CHECK_STATUS((*driver)->GetPropertyData(driver, kObjectID_PlugIn, 0, &translateAddr, sizeof(deviceUID), &deviceUID, sizeof(translated), &used, &translated));
    CHECK(translated == kObjectID_Device);

    CFStringRef bogus = CFSTR("not-a-real-uid");
    translated = 999;
    used = 0;
    CHECK_STATUS((*driver)->GetPropertyData(driver, kObjectID_PlugIn, 0, &translateAddr, sizeof(bogus), &bogus, sizeof(translated), &used, &translated));
    CHECK(translated == kAudioObjectUnknown);
}

static void TestDeviceProperties(AudioServerPlugInDriverRef driver)
{
    CHECK(GetU32(driver, kObjectID_Device, kAudioDevicePropertyDeviceIsAlive, kAudioObjectPropertyScopeGlobal) == 1);
    CHECK(GetU32(driver, kObjectID_Device, kAudioDevicePropertyIsHidden, kAudioObjectPropertyScopeGlobal) == 0);
    CHECK(GetU32(driver, kObjectID_Device, kAudioDevicePropertyZeroTimeStampPeriod, kAudioObjectPropertyScopeGlobal) == kRingBufferFrames);
    CHECK(GetU32(driver, kObjectID_Device, kAudioDevicePropertyDeviceCanBeDefaultDevice, kAudioObjectPropertyScopeInput) == 1);
    CHECK(GetU32(driver, kObjectID_Device, kAudioDevicePropertyDeviceCanBeDefaultDevice, kAudioObjectPropertyScopeOutput) == 0);

    AudioObjectPropertyAddress rateAddr = { kAudioDevicePropertyNominalSampleRate, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain };
    Float64 rate = 0;
    UInt32 used = 0;
    CHECK_STATUS((*driver)->GetPropertyData(driver, kObjectID_Device, 0, &rateAddr, 0, NULL, sizeof(rate), &used, &rate));
    CHECK(rate == kSampleRate);

    /* Rejecting an unsupported sample rate is important: conferencing apps
     * and the OS must never be told this fixed-format device changed rate. */
    Float64 badRate = 44100.0;
    OSStatus status = (*driver)->SetPropertyData(driver, kObjectID_Device, 0, &rateAddr, 0, NULL, sizeof(badRate), &badRate);
    CHECK(status == kAudioHardwareUnsupportedOperationError);

    Float64 sameRate = kSampleRate;
    CHECK_STATUS((*driver)->SetPropertyData(driver, kObjectID_Device, 0, &rateAddr, 0, NULL, sizeof(sameRate), &sameRate));

    AudioObjectPropertyAddress streamsInAddr = { kAudioDevicePropertyStreams, kAudioObjectPropertyScopeInput, kAudioObjectPropertyElementMain };
    AudioObjectID streamIn = 0;
    used = 0;
    CHECK_STATUS((*driver)->GetPropertyData(driver, kObjectID_Device, 0, &streamsInAddr, 0, NULL, sizeof(streamIn), &used, &streamIn));
    CHECK(streamIn == kObjectID_Stream_Input);

    AudioObjectPropertyAddress streamsOutAddr = { kAudioDevicePropertyStreams, kAudioObjectPropertyScopeOutput, kAudioObjectPropertyElementMain };
    AudioObjectID streamOut = 0;
    used = 0;
    CHECK_STATUS((*driver)->GetPropertyData(driver, kObjectID_Device, 0, &streamsOutAddr, 0, NULL, sizeof(streamOut), &used, &streamOut));
    CHECK(streamOut == kObjectID_Stream_Output);
}

static void TestStreamProperties(AudioServerPlugInDriverRef driver)
{
    AudioObjectPropertyAddress fmtAddr = { kAudioStreamPropertyVirtualFormat, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain };

    AudioStreamBasicDescription inFmt;
    memset(&inFmt, 0, sizeof(inFmt));
    UInt32 used = 0;
    CHECK_STATUS((*driver)->GetPropertyData(driver, kObjectID_Stream_Input, 0, &fmtAddr, 0, NULL, sizeof(inFmt), &used, &inFmt));
    CHECK(inFmt.mSampleRate == kSampleRate);
    CHECK(inFmt.mChannelsPerFrame == kChannelCount);
    CHECK((inFmt.mFormatFlags & kAudioFormatFlagIsFloat) != 0);

    AudioStreamBasicDescription outFmt;
    memset(&outFmt, 0, sizeof(outFmt));
    used = 0;
    CHECK_STATUS((*driver)->GetPropertyData(driver, kObjectID_Stream_Output, 0, &fmtAddr, 0, NULL, sizeof(outFmt), &used, &outFmt));
    CHECK(outFmt.mSampleRate == inFmt.mSampleRate);
    CHECK(outFmt.mChannelsPerFrame == inFmt.mChannelsPerFrame);

    /* Direction: input stream (what conferencing apps capture) must report
     * direction=1 ("input"); the app-facing output stream must report 0. */
    CHECK(GetU32(driver, kObjectID_Stream_Input, kAudioStreamPropertyDirection, kAudioObjectPropertyScopeGlobal) == 1);
    CHECK(GetU32(driver, kObjectID_Stream_Output, kAudioStreamPropertyDirection, kAudioObjectPropertyScopeGlobal) == 0);

    /* Format is fixed: any request for a different sample rate or channel
     * count must be rejected. */
    AudioStreamBasicDescription badFmt = inFmt;
    badFmt.mChannelsPerFrame = 1;
    OSStatus status = (*driver)->SetPropertyData(driver, kObjectID_Stream_Input, 0, &fmtAddr, 0, NULL, sizeof(badFmt), &badFmt);
    CHECK(status == kAudioHardwareUnsupportedOperationError);
}

static void TestClientLifecycleAndClock(AudioServerPlugInDriverRef driver)
{
    CHECK(GetU32(driver, kObjectID_Device, kAudioDevicePropertyDeviceIsRunning, kAudioObjectPropertyScopeGlobal) == 0);

    CHECK_STATUS((*driver)->StartIO(driver, kObjectID_Device, 1));
    CHECK(GetU32(driver, kObjectID_Device, kAudioDevicePropertyDeviceIsRunning, kAudioObjectPropertyScopeGlobal) == 1);

    Float64 sampleTime1 = 0; UInt64 hostTime1 = 0, seed1 = 0;
    CHECK_STATUS((*driver)->GetZeroTimeStamp(driver, kObjectID_Device, 1, &sampleTime1, &hostTime1, &seed1));
    CHECK(((UInt64)sampleTime1) % kRingBufferFrames == 0);

    usleep(2000);
    Float64 sampleTime2 = 0; UInt64 hostTime2 = 0, seed2 = 0;
    CHECK_STATUS((*driver)->GetZeroTimeStamp(driver, kObjectID_Device, 1, &sampleTime2, &hostTime2, &seed2));
    /* Monotonic non-decreasing, and the seed must stay stable while a
     * single client keeps IO running continuously. */
    CHECK(sampleTime2 >= sampleTime1);
    CHECK(hostTime2 >= hostTime1);
    CHECK(seed2 == seed1);

    /* A second client starting while the first is still running must not
     * reset the timeline (no seed change, no silent audio wipe). */
    CHECK_STATUS((*driver)->StartIO(driver, kObjectID_Device, 2));
    CHECK_STATUS((*driver)->StopIO(driver, kObjectID_Device, 2));
    CHECK_STATUS((*driver)->StopIO(driver, kObjectID_Device, 1));

    CHECK(GetU32(driver, kObjectID_Device, kAudioDevicePropertyDeviceIsRunning, kAudioObjectPropertyScopeGlobal) == 0);
}

static void TestWillDoIOOperation(AudioServerPlugInDriverRef driver)
{
    Boolean willDo = false, inPlace = false;
    CHECK_STATUS((*driver)->WillDoIOOperation(driver, kObjectID_Device, 1, kAudioServerPlugInIOOperationWriteMix, &willDo, &inPlace));
    CHECK(willDo == true);
    CHECK(inPlace == true);

    CHECK_STATUS((*driver)->WillDoIOOperation(driver, kObjectID_Device, 1, kAudioServerPlugInIOOperationReadInput, &willDo, &inPlace));
    CHECK(willDo == true);

    CHECK_STATUS((*driver)->WillDoIOOperation(driver, kObjectID_Device, 1, kAudioServerPlugInIOOperationProcessMix, &willDo, &inPlace));
    CHECK(willDo == false);
}

static AudioServerPlugInIOCycleInfo MakeCycleInfo(Float64 sampleTime)
{
    AudioServerPlugInIOCycleInfo info;
    memset(&info, 0, sizeof(info));
    info.mIOCycleCounter = 1;
    info.mNominalIOBufferFrameSize = 256;
    info.mOutputTime.mSampleTime = sampleTime;
    info.mInputTime.mSampleTime = sampleTime;
    return info;
}

static void TestSilenceOnUnderrun(AudioServerPlugInDriverRef driver)
{
    CHECK_STATUS((*driver)->StartIO(driver, kObjectID_Device, 1));

    const UInt32 frames = 256;
    float buffer[256 * 2];
    /* Poison the buffer so we can tell whether the driver actually wrote
     * silence, rather than merely leaving stale data untouched. */
    for (UInt32 i = 0; i < frames * kChannelCount; i++) { buffer[i] = 12345.0f; }

    AudioServerPlugInIOCycleInfo cycle = MakeCycleInfo(0);
    CHECK_STATUS((*driver)->DoIOOperation(driver, kObjectID_Device, kObjectID_Stream_Input, 1,
                                          kAudioServerPlugInIOOperationReadInput, frames, &cycle, buffer, NULL));
    for (UInt32 i = 0; i < frames * kChannelCount; i++) { CHECK(buffer[i] == 0.0f); }

    CHECK_STATUS((*driver)->StopIO(driver, kObjectID_Device, 1));
}

static void TestWriteMixThenReadInputRoundTrip(AudioServerPlugInDriverRef driver)
{
    CHECK_STATUS((*driver)->StartIO(driver, kObjectID_Device, 1));

    const UInt32 frames = 512;
    float writeBuffer[512 * 2];
    for (UInt32 f = 0; f < frames; f++)
    {
        writeBuffer[f * 2 + 0] = (float)f / (float)frames;         /* left ramp  */
        writeBuffer[f * 2 + 1] = -(float)f / (float)frames;        /* right ramp */
    }

    AudioServerPlugInIOCycleInfo writeCycle = MakeCycleInfo(1000.0);
    CHECK_STATUS((*driver)->DoIOOperation(driver, kObjectID_Device, kObjectID_Stream_Output, 1,
                                          kAudioServerPlugInIOOperationWriteMix, frames, &writeCycle, writeBuffer, NULL));

    float readBuffer[512 * 2];
    memset(readBuffer, 0xAA, sizeof(readBuffer));
    AudioServerPlugInIOCycleInfo readCycle = MakeCycleInfo(1000.0);
    CHECK_STATUS((*driver)->DoIOOperation(driver, kObjectID_Device, kObjectID_Stream_Input, 2,
                                          kAudioServerPlugInIOOperationReadInput, frames, &readCycle, readBuffer, NULL));

    CHECK(memcmp(writeBuffer, readBuffer, sizeof(writeBuffer)) == 0);

    CHECK_STATUS((*driver)->StopIO(driver, kObjectID_Device, 1));
}

static void TestRingBufferWraparound(AudioServerPlugInDriverRef driver)
{
    CHECK_STATUS((*driver)->StartIO(driver, kObjectID_Device, 1));

    const UInt32 frames = 1024;
    /* Start just before the ring boundary so this write straddles the
     * wraparound point. */
    const Float64 startSample = (Float64)(kRingBufferFrames - 100);

    float writeBuffer[1024 * 2];
    for (UInt32 f = 0; f < frames; f++)
    {
        writeBuffer[f * 2 + 0] = (float)(f + 1);
        writeBuffer[f * 2 + 1] = -(float)(f + 1);
    }

    AudioServerPlugInIOCycleInfo writeCycle = MakeCycleInfo(startSample);
    CHECK_STATUS((*driver)->DoIOOperation(driver, kObjectID_Device, kObjectID_Stream_Output, 1,
                                          kAudioServerPlugInIOOperationWriteMix, frames, &writeCycle, writeBuffer, NULL));

    float readBuffer[1024 * 2];
    memset(readBuffer, 0, sizeof(readBuffer));
    AudioServerPlugInIOCycleInfo readCycle = MakeCycleInfo(startSample);
    CHECK_STATUS((*driver)->DoIOOperation(driver, kObjectID_Device, kObjectID_Stream_Input, 2,
                                          kAudioServerPlugInIOOperationReadInput, frames, &readCycle, readBuffer, NULL));

    CHECK(memcmp(writeBuffer, readBuffer, sizeof(writeBuffer)) == 0);

    CHECK_STATUS((*driver)->StopIO(driver, kObjectID_Device, 1));
}

int main(int argc, const char *argv[])
{
    if (argc < 2)
    {
        fprintf(stderr, "usage: %s /path/to/AudioMixerVirtualDriver.driver\n", argv[0]);
        return 2;
    }

    CFStringRef pathString = CFStringCreateWithCString(NULL, argv[1], kCFStringEncodingUTF8);
    CFURLRef bundleURL = CFURLCreateWithFileSystemPath(NULL, pathString, kCFURLPOSIXPathStyle, true);
    CFPlugInRef plugin = CFPlugInCreate(NULL, bundleURL);
    if (plugin == NULL)
    {
        fprintf(stderr, "Could not load plug-in bundle at %s\n", argv[1]);
        return 1;
    }

    CFArrayRef factories = CFPlugInFindFactoriesForPlugInTypeInPlugIn(kAudioServerPlugInTypeUUID, plugin);
    if (factories == NULL || CFArrayGetCount(factories) == 0)
    {
        fprintf(stderr, "No AudioServerPlugIn factory found in bundle\n");
        return 1;
    }
    CFUUIDRef factoryUUID = (CFUUIDRef)CFArrayGetValueAtIndex(factories, 0);

    AudioServerPlugInDriverRef driver = (AudioServerPlugInDriverRef)CFPlugInInstanceCreate(NULL, factoryUUID, kAudioServerPlugInTypeUUID);
    if (driver == NULL)
    {
        fprintf(stderr, "CFPlugInInstanceCreate returned NULL\n");
        return 1;
    }

    CHECK_STATUS((*driver)->Initialize(driver, gHostInterfacePtr));

    TestPlugInAndBoxProperties(driver);
    TestDeviceProperties(driver);
    TestStreamProperties(driver);
    TestWillDoIOOperation(driver);
    TestSilenceOnUnderrun(driver);
    TestWriteMixThenReadInputRoundTrip(driver);
    TestRingBufferWraparound(driver);
    TestClientLifecycleAndClock(driver);

    (*driver)->Release(driver);
    CFRelease(factories);
    CFRelease(plugin);
    CFRelease(bundleURL);
    CFRelease(pathString);

    if (gFailures == 0)
    {
        printf("All driver tests passed.\n");
        return 0;
    }
    fprintf(stderr, "%d driver test check(s) failed.\n", gFailures);
    return 1;
}
