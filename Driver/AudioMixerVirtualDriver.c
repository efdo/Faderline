/*
 * AudioMixerVirtualDriver.c
 *
 * A minimal AudioServerPlugIn ("HAL plug-in") that exposes a single fixed
 * stereo, 48 kHz, Float32 loopback device named "AudioMixer Virtual
 * Microphone". AudioMixer writes its mixed bus to the device's output
 * stream via a normal AUHAL output unit; conferencing apps (Teams, Zoom,
 * etc.) read the same frames back from the device's input stream via a
 * normal AUHAL input unit.
 *
 * This file is an independent, clean-room implementation written directly
 * against Apple's public <CoreAudio/AudioServerPlugIn.h> interface
 * specification. It does not reuse code from any third-party driver.
 *
 * Real-time constraints: DoIOOperation (and everything it calls) runs on
 * coreaudiod's real-time IO thread. It must not allocate, lock, log, or
 * block. All state touched there is a plain fixed-size buffer plus a
 * handful of C11 atomics.
 */

#include <CoreFoundation/CoreFoundation.h>
#include <CoreFoundation/CFPlugInCOM.h>
#include <CoreAudio/AudioServerPlugIn.h>
#include <mach/mach_time.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>

#pragma mark - Object IDs

/* The plug-in object itself is always AudioObjectID 1 (kAudioObjectPlugInObject).
 * We define the rest of our fixed, static object graph starting at 2. */
enum
{
    kObjectID_PlugIn        = kAudioObjectPlugInObject,
    kObjectID_Box           = 2,
    kObjectID_Device        = 3,
    kObjectID_Stream_Input  = 4,
    kObjectID_Stream_Output = 5,
};

#pragma mark - Fixed device configuration

static const Float64 kDevice_SampleRate         = 48000.0;
static const UInt32  kDevice_ChannelCount       = 2;
static const UInt32  kDevice_BitsPerChannel     = 32;
static const UInt32  kDevice_BytesPerFrame      = 8;  /* 2 ch * 4 bytes, interleaved */
/* Frames per ring cycle. Must be >= 10923 per kAudioDevicePropertyZeroTimeStampPeriod's
 * documented minimum; ~1.37s at 48kHz gives generous headroom between the
 * producer (AudioMixer) and consumer (conferencing app) IO cycles. */
static const UInt32  kDevice_RingBufferFrames   = 65536;

/* kAudioDevicePropertyStreamConfiguration ('slay') is declared in
 * AudioHardware.h, the *client*-side HAL API, which an AudioServerPlugIn
 * must not link against. The selector value itself is a stable, public
 * FourCharCode; declare it locally instead of including that header. */
enum { kDriverSelector_StreamConfiguration = 'slay' };

#pragma mark - Global driver state

/* Everything the RT IO path touches lives in this struct. It is allocated
 * once at load time and never freed (the process is torn down by
 * coreaudiod exiting, not by us). */
typedef struct
{
    /* Interleaved Float32 stereo ring, `kDevice_RingBufferFrames` frames long. */
    float *mRingBuffer;

    /* Highest (exclusive) sample-time index written so far by WriteMix, or
     * -1 if nothing has been written yet. Written with release ordering by
     * the (single) producer, read with acquire ordering by the consumer. */
    _Atomic int64_t mWriteHighWaterMark;

    /* Number of clients that currently have IO started on the device
     * (across both directions). Only touched under gLifecycleLock. */
    UInt32 mRunningClientCount;

    /* Synthetic clock: anchor host time for sample-time 0 of the current
     * timeline, and how many mach host-time ticks correspond to one frame
     * at the nominal sample rate. Recomputed each time IO restarts from
     * idle so a fresh timeline begins. */
    UInt64 mAnchorHostTime;
    Float64 mHostTicksPerFrame;
    _Atomic uint64_t mClockSeed;
} DriverState;

static DriverState gState;

/* Protects everything that is not on the RT IO path: reference counting,
 * client add/remove bookkeeping, and StartIO/StopIO transitions. Never
 * taken inside DoIOOperation/GetZeroTimeStamp. */
static pthread_mutex_t gLifecycleLock = PTHREAD_MUTEX_INITIALIZER;

static AudioServerPlugInHostRef gHost = NULL;

#pragma mark - IUnknown / CFPlugIn boilerplate

static HRESULT AudioMixerVirtualDriver_QueryInterface(void *inDriver, REFIID inUUID, LPVOID *outInterface);
static ULONG   AudioMixerVirtualDriver_AddRef(void *inDriver);
static ULONG   AudioMixerVirtualDriver_Release(void *inDriver);

static OSStatus AudioMixerVirtualDriver_Initialize(AudioServerPlugInDriverRef inDriver, AudioServerPlugInHostRef inHost);
static OSStatus AudioMixerVirtualDriver_CreateDevice(AudioServerPlugInDriverRef inDriver, CFDictionaryRef inDescription, const AudioServerPlugInClientInfo *inClientInfo, AudioObjectID *outDeviceObjectID);
static OSStatus AudioMixerVirtualDriver_DestroyDevice(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID);
static OSStatus AudioMixerVirtualDriver_AddDeviceClient(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, const AudioServerPlugInClientInfo *inClientInfo);
static OSStatus AudioMixerVirtualDriver_RemoveDeviceClient(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, const AudioServerPlugInClientInfo *inClientInfo);
static OSStatus AudioMixerVirtualDriver_PerformDeviceConfigurationChange(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt64 inChangeAction, void *inChangeInfo);
static OSStatus AudioMixerVirtualDriver_AbortDeviceConfigurationChange(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt64 inChangeAction, void *inChangeInfo);

static Boolean  AudioMixerVirtualDriver_HasProperty(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress *inAddress);
static OSStatus AudioMixerVirtualDriver_IsPropertySettable(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress *inAddress, Boolean *outIsSettable);
static OSStatus AudioMixerVirtualDriver_GetPropertyDataSize(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress *inAddress, UInt32 inQualifierDataSize, const void *inQualifierData, UInt32 *outDataSize);
static OSStatus AudioMixerVirtualDriver_GetPropertyData(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress *inAddress, UInt32 inQualifierDataSize, const void *inQualifierData, UInt32 inDataSize, UInt32 *outDataSize, void *outData);
static OSStatus AudioMixerVirtualDriver_SetPropertyData(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress *inAddress, UInt32 inQualifierDataSize, const void *inQualifierData, UInt32 inDataSize, const void *inData);

static OSStatus AudioMixerVirtualDriver_StartIO(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID);
static OSStatus AudioMixerVirtualDriver_StopIO(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID);
static OSStatus AudioMixerVirtualDriver_GetZeroTimeStamp(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID, Float64 *outSampleTime, UInt64 *outHostTime, UInt64 *outSeed);
static OSStatus AudioMixerVirtualDriver_WillDoIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID, UInt32 inOperationID, Boolean *outWillDo, Boolean *outWillDoInPlace);
static OSStatus AudioMixerVirtualDriver_BeginIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID, UInt32 inOperationID, UInt32 inIOBufferFrameSize, const AudioServerPlugInIOCycleInfo *inIOCycleInfo);
static OSStatus AudioMixerVirtualDriver_DoIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, AudioObjectID inStreamObjectID, UInt32 inClientID, UInt32 inOperationID, UInt32 inIOBufferFrameSize, const AudioServerPlugInIOCycleInfo *inIOCycleInfo, void *ioMainBuffer, void *ioSecondaryBuffer);
static OSStatus AudioMixerVirtualDriver_EndIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID, UInt32 inOperationID, UInt32 inIOBufferFrameSize, const AudioServerPlugInIOCycleInfo *inIOCycleInfo);

static AudioServerPlugInDriverInterface gDriverInterface = {
    .QueryInterface                     = AudioMixerVirtualDriver_QueryInterface,
    .AddRef                             = AudioMixerVirtualDriver_AddRef,
    .Release                            = AudioMixerVirtualDriver_Release,
    .Initialize                         = AudioMixerVirtualDriver_Initialize,
    .CreateDevice                       = AudioMixerVirtualDriver_CreateDevice,
    .DestroyDevice                      = AudioMixerVirtualDriver_DestroyDevice,
    .AddDeviceClient                    = AudioMixerVirtualDriver_AddDeviceClient,
    .RemoveDeviceClient                 = AudioMixerVirtualDriver_RemoveDeviceClient,
    .PerformDeviceConfigurationChange   = AudioMixerVirtualDriver_PerformDeviceConfigurationChange,
    .AbortDeviceConfigurationChange     = AudioMixerVirtualDriver_AbortDeviceConfigurationChange,
    .HasProperty                        = AudioMixerVirtualDriver_HasProperty,
    .IsPropertySettable                 = AudioMixerVirtualDriver_IsPropertySettable,
    .GetPropertyDataSize                = AudioMixerVirtualDriver_GetPropertyDataSize,
    .GetPropertyData                    = AudioMixerVirtualDriver_GetPropertyData,
    .SetPropertyData                    = AudioMixerVirtualDriver_SetPropertyData,
    .StartIO                            = AudioMixerVirtualDriver_StartIO,
    .StopIO                             = AudioMixerVirtualDriver_StopIO,
    .GetZeroTimeStamp                   = AudioMixerVirtualDriver_GetZeroTimeStamp,
    .WillDoIOOperation                  = AudioMixerVirtualDriver_WillDoIOOperation,
    .BeginIOOperation                   = AudioMixerVirtualDriver_BeginIOOperation,
    .DoIOOperation                      = AudioMixerVirtualDriver_DoIOOperation,
    .EndIOOperation                     = AudioMixerVirtualDriver_EndIOOperation,
};

static AudioServerPlugInDriverInterface *gDriverInterfacePtr = &gDriverInterface;
static AudioServerPlugInDriverRef gDriverRef = &gDriverInterfacePtr;
static _Atomic ULONG gDriverRefCount = 1;

/* CFPlugIn factory entry point, referenced by Info.plist's CFPlugInFactories. */
void *AudioMixerVirtualDriver_Create(CFAllocatorRef allocator, CFUUIDRef typeID);

void *AudioMixerVirtualDriver_Create(CFAllocatorRef allocator, CFUUIDRef typeID)
{
    (void)allocator;
    if (typeID != NULL && CFEqual(typeID, kAudioServerPlugInTypeUUID))
    {
        AudioMixerVirtualDriver_AddRef(gDriverRef);
        return gDriverRef;
    }
    return NULL;
}

static HRESULT AudioMixerVirtualDriver_QueryInterface(void *inDriver, REFIID inUUID, LPVOID *outInterface)
{
    if (outInterface == NULL) { return E_INVALIDARG; }
    *outInterface = NULL;

    CFUUIDRef requested = CFUUIDCreateFromUUIDBytes(NULL, inUUID);
    if (requested == NULL) { return E_INVALIDARG; }

    HRESULT result = E_NOINTERFACE;
    if (CFEqual(requested, IUnknownUUID) || CFEqual(requested, kAudioServerPlugInDriverInterfaceUUID))
    {
        AudioMixerVirtualDriver_AddRef(inDriver);
        *outInterface = gDriverRef;
        result = S_OK;
    }
    CFRelease(requested);
    return result;
}

static ULONG AudioMixerVirtualDriver_AddRef(void *inDriver)
{
    (void)inDriver;
    return (ULONG)(atomic_fetch_add_explicit(&gDriverRefCount, 1, memory_order_relaxed) + 1);
}

static ULONG AudioMixerVirtualDriver_Release(void *inDriver)
{
    (void)inDriver;
    ULONG previous = (ULONG)atomic_fetch_sub_explicit(&gDriverRefCount, 1, memory_order_relaxed);
    /* The driver is a static singleton for the lifetime of the host
     * process; we never actually tear it down when the count hits zero. */
    return previous > 0 ? previous - 1 : 0;
}

#pragma mark - CFStrings (leaked intentionally: process-lifetime constants)

static CFStringRef CopyManufacturerName(void)      { return CFSTR("AudioMixer"); }
static CFStringRef CopyBoxName(void)                { return CFSTR("AudioMixer Virtual Audio"); }
static CFStringRef CopyDeviceName(void)             { return CFSTR("AudioMixer Virtual Microphone"); }
static CFStringRef CopyBoxUID(void)                 { return CFSTR("com.audiomixer.virtualmic.box"); }
static CFStringRef CopyDeviceUID(void)              { return CFSTR("com.audiomixer.virtualmic.device"); }
static CFStringRef CopyDeviceModelUID(void)         { return CFSTR("com.audiomixer.virtualmic.model"); }

#pragma mark - Basic Operations

static OSStatus AudioMixerVirtualDriver_Initialize(AudioServerPlugInDriverRef inDriver, AudioServerPlugInHostRef inHost)
{
    (void)inDriver;
    gHost = inHost;

    memset(&gState, 0, sizeof(gState));
    gState.mRingBuffer = (float *)calloc((size_t)kDevice_RingBufferFrames * kDevice_ChannelCount, sizeof(float));
    if (gState.mRingBuffer == NULL) { return kAudioHardwareUnspecifiedError; }
    atomic_store_explicit(&gState.mWriteHighWaterMark, -1, memory_order_relaxed);
    atomic_store_explicit(&gState.mClockSeed, 1, memory_order_relaxed);

    mach_timebase_info_data_t timebase;
    mach_timebase_info(&timebase);
    /* Host ticks per frame at the nominal sample rate. mach_absolute_time
     * ticks convert to nanoseconds via (ticks * numer / denom); inverting
     * that for "ticks per frame" gives ticks = seconds * 1e9 * denom/numer. */
    gState.mHostTicksPerFrame = (1.0e9 / kDevice_SampleRate) * ((Float64)timebase.denom / (Float64)timebase.numer);
    gState.mAnchorHostTime = mach_absolute_time();

    /* The device/box/streams are always published (this driver has a
     * fixed, static object graph), so there is nothing further to
     * announce to the host at this point. */
    return kAudioHardwareNoError;
}

static OSStatus AudioMixerVirtualDriver_CreateDevice(AudioServerPlugInDriverRef inDriver, CFDictionaryRef inDescription, const AudioServerPlugInClientInfo *inClientInfo, AudioObjectID *outDeviceObjectID)
{
    (void)inDriver; (void)inDescription; (void)inClientInfo; (void)outDeviceObjectID;
    /* This driver exposes exactly one static device; it does not support
     * creating additional devices on demand (e.g. for aggregate devices). */
    return kAudioHardwareUnsupportedOperationError;
}

static OSStatus AudioMixerVirtualDriver_DestroyDevice(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID)
{
    (void)inDriver; (void)inDeviceObjectID;
    return kAudioHardwareUnsupportedOperationError;
}

static OSStatus AudioMixerVirtualDriver_AddDeviceClient(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, const AudioServerPlugInClientInfo *inClientInfo)
{
    (void)inDriver; (void)inDeviceObjectID; (void)inClientInfo;
    /* No per-client bookkeeping is required beyond the IO reference count
     * maintained in StartIO/StopIO. */
    return kAudioHardwareNoError;
}

static OSStatus AudioMixerVirtualDriver_RemoveDeviceClient(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, const AudioServerPlugInClientInfo *inClientInfo)
{
    (void)inDriver; (void)inDeviceObjectID; (void)inClientInfo;
    return kAudioHardwareNoError;
}

static OSStatus AudioMixerVirtualDriver_PerformDeviceConfigurationChange(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt64 inChangeAction, void *inChangeInfo)
{
    (void)inDriver; (void)inDeviceObjectID; (void)inChangeAction; (void)inChangeInfo;
    /* The device's format and structure are fixed; it never requests a
     * configuration change, so the host should never call this. */
    return kAudioHardwareNoError;
}

static OSStatus AudioMixerVirtualDriver_AbortDeviceConfigurationChange(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt64 inChangeAction, void *inChangeInfo)
{
    (void)inDriver; (void)inDeviceObjectID; (void)inChangeAction; (void)inChangeInfo;
    return kAudioHardwareNoError;
}

#pragma mark - Property helpers

static Boolean UIDMatches(CFStringRef candidate, CFStringRef (*copyUID)(void))
{
    CFStringRef uid = copyUID();
    Boolean result = candidate != NULL && CFEqual(candidate, uid);
    return result;
}

static AudioStreamBasicDescription FixedStreamFormat(void)
{
    AudioStreamBasicDescription fmt;
    memset(&fmt, 0, sizeof(fmt));
    fmt.mSampleRate       = kDevice_SampleRate;
    fmt.mFormatID         = kAudioFormatLinearPCM;
    fmt.mFormatFlags      = kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked;
    fmt.mBytesPerPacket   = kDevice_BytesPerFrame;
    fmt.mFramesPerPacket  = 1;
    fmt.mBytesPerFrame    = kDevice_BytesPerFrame;
    fmt.mChannelsPerFrame = kDevice_ChannelCount;
    fmt.mBitsPerChannel   = kDevice_BitsPerChannel;
    return fmt;
}

/* Shared implementation for GetPropertyDataSize / GetPropertyData: when
 * `isSizeQuery` is true, only `*outDataSize` is written (`outData` may be
 * NULL); otherwise the property value is copied into `outData` (whose
 * capacity is `inDataSize`) and `*outDataSize` receives the number of
 * bytes written. Not on the RT IO path, so CF calls are fine here. */
static OSStatus CopyPropertyValue(AudioObjectID inObjectID,
                                   const AudioObjectPropertyAddress *inAddress,
                                   UInt32 inQualifierDataSize,
                                   const void *inQualifierData,
                                   UInt32 inDataSize,
                                   UInt32 *outDataSize,
                                   void *outData,
                                   Boolean isSizeQuery)
{
#define YIELD_BYTES(ptr, size) \
    do { \
        *outDataSize = (UInt32)(size); \
        if (!isSizeQuery) { \
            if (inDataSize < (UInt32)(size)) { return kAudioHardwareBadPropertySizeError; } \
            memcpy(outData, (ptr), (size)); \
        } \
        return kAudioHardwareNoError; \
    } while (0)

#define YIELD_VALUE(type, value) \
    do { type _v = (value); YIELD_BYTES(&_v, sizeof(_v)); } while (0)

#define YIELD_CFSTRING(copyFn) \
    do { \
        CFStringRef _s = copyFn(); \
        YIELD_VALUE(CFStringRef, _s); \
    } while (0)

    const AudioObjectPropertySelector selector = inAddress->mSelector;
    const AudioObjectPropertyScope scope = inAddress->mScope;

    switch (inObjectID)
    {
        case kObjectID_PlugIn:
        {
            switch (selector)
            {
                case kAudioObjectPropertyBaseClass:      YIELD_VALUE(AudioClassID, kAudioObjectClassID);
                case kAudioObjectPropertyClass:           YIELD_VALUE(AudioClassID, kAudioPlugInClassID);
                case kAudioObjectPropertyOwner:            YIELD_VALUE(AudioObjectID, kAudioObjectUnknown);
                case kAudioObjectPropertyManufacturer:    YIELD_CFSTRING(CopyManufacturerName);
                case kAudioObjectPropertyOwnedObjects:
                {
                    AudioObjectID owned[2] = { kObjectID_Box, kObjectID_Device };
                    YIELD_BYTES(owned, sizeof(owned));
                }
                case kAudioPlugInPropertyBoxList:
                {
                    AudioObjectID box = kObjectID_Box;
                    YIELD_BYTES(&box, sizeof(box));
                }
                case kAudioPlugInPropertyDeviceList:
                {
                    AudioObjectID device = kObjectID_Device;
                    YIELD_BYTES(&device, sizeof(device));
                }
                case kAudioPlugInPropertyTranslateUIDToBox:
                {
                    CFStringRef candidate = inQualifierDataSize >= sizeof(CFStringRef) ? *(CFStringRef *)inQualifierData : NULL;
                    AudioObjectID result = UIDMatches(candidate, CopyBoxUID) ? kObjectID_Box : kAudioObjectUnknown;
                    YIELD_VALUE(AudioObjectID, result);
                }
                case kAudioPlugInPropertyTranslateUIDToDevice:
                {
                    CFStringRef candidate = inQualifierDataSize >= sizeof(CFStringRef) ? *(CFStringRef *)inQualifierData : NULL;
                    AudioObjectID result = UIDMatches(candidate, CopyDeviceUID) ? kObjectID_Device : kAudioObjectUnknown;
                    YIELD_VALUE(AudioObjectID, result);
                }
                default: return kAudioHardwareUnknownPropertyError;
            }
        }

        case kObjectID_Box:
        {
            switch (selector)
            {
                case kAudioObjectPropertyBaseClass:   YIELD_VALUE(AudioClassID, kAudioObjectClassID);
                case kAudioObjectPropertyClass:        YIELD_VALUE(AudioClassID, kAudioBoxClassID);
                case kAudioObjectPropertyOwner:         YIELD_VALUE(AudioObjectID, kObjectID_PlugIn);
                case kAudioObjectPropertyName:         YIELD_CFSTRING(CopyBoxName);
                case kAudioObjectPropertyManufacturer: YIELD_CFSTRING(CopyManufacturerName);
                case kAudioObjectPropertyOwnedObjects:
                case kAudioBoxPropertyDeviceList:
                {
                    AudioObjectID device = kObjectID_Device;
                    YIELD_BYTES(&device, sizeof(device));
                }
                case kAudioBoxPropertyBoxUID:          YIELD_CFSTRING(CopyBoxUID);
                case kAudioBoxPropertyTransportType:   YIELD_VALUE(UInt32, kAudioDeviceTransportTypeVirtual);
                case kAudioBoxPropertyHasAudio:        YIELD_VALUE(UInt32, 1);
                case kAudioBoxPropertyHasVideo:        YIELD_VALUE(UInt32, 0);
                case kAudioBoxPropertyHasMIDI:         YIELD_VALUE(UInt32, 0);
                case kAudioBoxPropertyIsProtected:     YIELD_VALUE(UInt32, 0);
                case kAudioBoxPropertyAcquired:        YIELD_VALUE(UInt32, 1);
                default: return kAudioHardwareUnknownPropertyError;
            }
        }

        case kObjectID_Device:
        {
            switch (selector)
            {
                case kAudioObjectPropertyBaseClass:   YIELD_VALUE(AudioClassID, kAudioObjectClassID);
                case kAudioObjectPropertyClass:        YIELD_VALUE(AudioClassID, kAudioDeviceClassID);
                case kAudioObjectPropertyOwner:         YIELD_VALUE(AudioObjectID, kObjectID_PlugIn);
                case kAudioObjectPropertyName:         YIELD_CFSTRING(CopyDeviceName);
                case kAudioObjectPropertyManufacturer: YIELD_CFSTRING(CopyManufacturerName);
                case kAudioObjectPropertyOwnedObjects:
                {
                    AudioObjectID owned[2] = { kObjectID_Stream_Input, kObjectID_Stream_Output };
                    YIELD_BYTES(owned, sizeof(owned));
                }
                case kAudioObjectPropertyControlList:
                    *outDataSize = 0;
                    return kAudioHardwareNoError;
                case kAudioDevicePropertyDeviceUID:       YIELD_CFSTRING(CopyDeviceUID);
                case kAudioDevicePropertyModelUID:        YIELD_CFSTRING(CopyDeviceModelUID);
                case kAudioDevicePropertyTransportType:   YIELD_VALUE(UInt32, kAudioDeviceTransportTypeVirtual);
                case kAudioDevicePropertyRelatedDevices:
                {
                    AudioObjectID device = kObjectID_Device;
                    YIELD_BYTES(&device, sizeof(device));
                }
                case kAudioDevicePropertyClockDomain:      YIELD_VALUE(UInt32, 0);
                case kAudioDevicePropertyDeviceIsAlive:    YIELD_VALUE(UInt32, 1);
                case kAudioDevicePropertyDeviceIsRunning:
                {
                    pthread_mutex_lock(&gLifecycleLock);
                    UInt32 running = gState.mRunningClientCount > 0 ? 1 : 0;
                    pthread_mutex_unlock(&gLifecycleLock);
                    YIELD_VALUE(UInt32, running);
                }
                case kAudioDevicePropertyLatency:          YIELD_VALUE(UInt32, 0);
                case kAudioDevicePropertySafetyOffset:     YIELD_VALUE(UInt32, 0);
                case kAudioDevicePropertyNominalSampleRate: YIELD_VALUE(Float64, kDevice_SampleRate);
                case kAudioDevicePropertyAvailableNominalSampleRates:
                {
                    AudioValueRange range = { kDevice_SampleRate, kDevice_SampleRate };
                    YIELD_BYTES(&range, sizeof(range));
                }
                case kAudioDevicePropertyIsHidden:          YIELD_VALUE(UInt32, 0);
                case kAudioDevicePropertyZeroTimeStampPeriod: YIELD_VALUE(UInt32, kDevice_RingBufferFrames);
                case kAudioDevicePropertyPreferredChannelsForStereo:
                {
                    UInt32 pair[2] = { 1, 2 };
                    YIELD_BYTES(pair, sizeof(pair));
                }
                case kAudioDevicePropertyDeviceCanBeDefaultDevice:
                    YIELD_VALUE(UInt32, scope == kAudioObjectPropertyScopeInput ? 1 : 0);
                case kAudioDevicePropertyDeviceCanBeDefaultSystemDevice:
                    YIELD_VALUE(UInt32, 0);
                case kAudioDevicePropertyStreams:
                {
                    if (scope == kAudioObjectPropertyScopeInput)
                    {
                        AudioObjectID s = kObjectID_Stream_Input;
                        YIELD_BYTES(&s, sizeof(s));
                    }
                    else if (scope == kAudioObjectPropertyScopeOutput)
                    {
                        AudioObjectID s = kObjectID_Stream_Output;
                        YIELD_BYTES(&s, sizeof(s));
                    }
                    else
                    {
                        AudioObjectID both[2] = { kObjectID_Stream_Input, kObjectID_Stream_Output };
                        YIELD_BYTES(both, sizeof(both));
                    }
                }
                case kDriverSelector_StreamConfiguration:
                {
                    /* Fixed-size AudioBufferList with exactly one buffer of
                     * kDevice_ChannelCount interleaved channels. */
                    struct { UInt32 count; AudioBuffer buffer; } list;
                    list.count = 1;
                    list.buffer.mNumberChannels = kDevice_ChannelCount;
                    list.buffer.mDataByteSize = 0;
                    list.buffer.mData = NULL;
                    if (scope != kAudioObjectPropertyScopeInput && scope != kAudioObjectPropertyScopeOutput)
                    {
                        return kAudioHardwareUnknownPropertyError;
                    }
                    YIELD_BYTES(&list, sizeof(list));
                }
                default: return kAudioHardwareUnknownPropertyError;
            }
        }

        case kObjectID_Stream_Input:
        case kObjectID_Stream_Output:
        {
            const Boolean isInput = inObjectID == kObjectID_Stream_Input;
            switch (selector)
            {
                case kAudioObjectPropertyBaseClass:   YIELD_VALUE(AudioClassID, kAudioObjectClassID);
                case kAudioObjectPropertyClass:        YIELD_VALUE(AudioClassID, kAudioStreamClassID);
                case kAudioObjectPropertyOwner:         YIELD_VALUE(AudioObjectID, kObjectID_Device);
                case kAudioObjectPropertyOwnedObjects:
                    *outDataSize = 0;
                    return kAudioHardwareNoError;
                case kAudioStreamPropertyIsActive:      YIELD_VALUE(UInt32, 1);
                case kAudioStreamPropertyDirection:     YIELD_VALUE(UInt32, isInput ? 1 : 0);
                case kAudioStreamPropertyTerminalType:
                    YIELD_VALUE(UInt32, isInput ? kAudioStreamTerminalTypeMicrophone : kAudioStreamTerminalTypeSpeaker);
                case kAudioStreamPropertyStartingChannel: YIELD_VALUE(UInt32, 1);
                case kAudioStreamPropertyLatency:         YIELD_VALUE(UInt32, 0);
                case kAudioStreamPropertyVirtualFormat:
                case kAudioStreamPropertyPhysicalFormat:
                {
                    AudioStreamBasicDescription fmt = FixedStreamFormat();
                    YIELD_BYTES(&fmt, sizeof(fmt));
                }
                case kAudioStreamPropertyAvailableVirtualFormats:
                case kAudioStreamPropertyAvailablePhysicalFormats:
                {
                    AudioStreamRangedDescription ranged;
                    ranged.mFormat = FixedStreamFormat();
                    ranged.mSampleRateRange.mMinimum = kDevice_SampleRate;
                    ranged.mSampleRateRange.mMaximum = kDevice_SampleRate;
                    YIELD_BYTES(&ranged, sizeof(ranged));
                }
                default: return kAudioHardwareUnknownPropertyError;
            }
        }

        default:
            return kAudioHardwareBadObjectError;
    }

#undef YIELD_CFSTRING
#undef YIELD_VALUE
#undef YIELD_BYTES
}

#pragma mark - Property Operations

static Boolean AudioMixerVirtualDriver_HasProperty(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress *inAddress)
{
    (void)inDriver; (void)inClientProcessID;
    UInt32 size = 0;
    OSStatus status = CopyPropertyValue(inObjectID, inAddress, 0, NULL, 0, &size, NULL, true);
    return status == kAudioHardwareNoError;
}

static OSStatus AudioMixerVirtualDriver_IsPropertySettable(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress *inAddress, Boolean *outIsSettable)
{
    (void)inDriver; (void)inClientProcessID;
    if (outIsSettable == NULL) { return kAudioHardwareIllegalOperationError; }

    switch (inObjectID)
    {
        case kObjectID_Device:
            *outIsSettable = inAddress->mSelector == kAudioDevicePropertyNominalSampleRate;
            return kAudioHardwareNoError;
        case kObjectID_Stream_Input:
        case kObjectID_Stream_Output:
            *outIsSettable = inAddress->mSelector == kAudioStreamPropertyVirtualFormat
                          || inAddress->mSelector == kAudioStreamPropertyPhysicalFormat;
            return kAudioHardwareNoError;
        default:
            *outIsSettable = false;
            return kAudioHardwareNoError;
    }
}

static OSStatus AudioMixerVirtualDriver_GetPropertyDataSize(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress *inAddress, UInt32 inQualifierDataSize, const void *inQualifierData, UInt32 *outDataSize)
{
    (void)inDriver; (void)inClientProcessID;
    if (outDataSize == NULL) { return kAudioHardwareIllegalOperationError; }
    return CopyPropertyValue(inObjectID, inAddress, inQualifierDataSize, inQualifierData, 0, outDataSize, NULL, true);
}

static OSStatus AudioMixerVirtualDriver_GetPropertyData(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress *inAddress, UInt32 inQualifierDataSize, const void *inQualifierData, UInt32 inDataSize, UInt32 *outDataSize, void *outData)
{
    (void)inDriver; (void)inClientProcessID;
    if (outDataSize == NULL || outData == NULL) { return kAudioHardwareIllegalOperationError; }
    return CopyPropertyValue(inObjectID, inAddress, inQualifierDataSize, inQualifierData, inDataSize, outDataSize, outData, false);
}

static OSStatus AudioMixerVirtualDriver_SetPropertyData(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress *inAddress, UInt32 inQualifierDataSize, const void *inQualifierData, UInt32 inDataSize, const void *inData)
{
    (void)inDriver; (void)inClientProcessID; (void)inQualifierDataSize; (void)inQualifierData;

    /* The device's format is fixed. The only "set" we accept is one that
     * requests the value we already report; anything else is rejected so
     * clients get a clear error instead of a silently-ignored change. */
    if (inObjectID == kObjectID_Device && inAddress->mSelector == kAudioDevicePropertyNominalSampleRate)
    {
        if (inDataSize < sizeof(Float64)) { return kAudioHardwareBadPropertySizeError; }
        Float64 requested = *(const Float64 *)inData;
        return requested == kDevice_SampleRate ? kAudioHardwareNoError : kAudioHardwareUnsupportedOperationError;
    }
    if ((inObjectID == kObjectID_Stream_Input || inObjectID == kObjectID_Stream_Output)
        && (inAddress->mSelector == kAudioStreamPropertyVirtualFormat || inAddress->mSelector == kAudioStreamPropertyPhysicalFormat))
    {
        if (inDataSize < sizeof(AudioStreamBasicDescription)) { return kAudioHardwareBadPropertySizeError; }
        AudioStreamBasicDescription requested = *(const AudioStreamBasicDescription *)inData;
        AudioStreamBasicDescription fixed = FixedStreamFormat();
        Boolean matches = requested.mSampleRate == fixed.mSampleRate
                        && requested.mFormatID == fixed.mFormatID
                        && requested.mChannelsPerFrame == fixed.mChannelsPerFrame
                        && requested.mBitsPerChannel == fixed.mBitsPerChannel;
        return matches ? kAudioHardwareNoError : kAudioHardwareUnsupportedOperationError;
    }
    return kAudioHardwareUnsupportedOperationError;
}

#pragma mark - IO Operations

static OSStatus AudioMixerVirtualDriver_StartIO(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID)
{
    (void)inDriver; (void)inDeviceObjectID; (void)inClientID;
    pthread_mutex_lock(&gLifecycleLock);
    if (gState.mRunningClientCount == 0)
    {
        /* First client to start IO after being fully idle: begin a fresh
         * clock timeline and clear any stale ring-buffer content so a
         * newly-connected reader can never see audio from a previous,
         * unrelated session. */
        gState.mAnchorHostTime = mach_absolute_time();
        atomic_store_explicit(&gState.mWriteHighWaterMark, -1, memory_order_relaxed);
        atomic_fetch_add_explicit(&gState.mClockSeed, 1, memory_order_relaxed);
        memset(gState.mRingBuffer, 0, (size_t)kDevice_RingBufferFrames * kDevice_ChannelCount * sizeof(float));
    }
    gState.mRunningClientCount += 1;
    pthread_mutex_unlock(&gLifecycleLock);
    return kAudioHardwareNoError;
}

static OSStatus AudioMixerVirtualDriver_StopIO(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID)
{
    (void)inDriver; (void)inDeviceObjectID; (void)inClientID;
    pthread_mutex_lock(&gLifecycleLock);
    if (gState.mRunningClientCount > 0) { gState.mRunningClientCount -= 1; }
    pthread_mutex_unlock(&gLifecycleLock);
    return kAudioHardwareNoError;
}

static OSStatus AudioMixerVirtualDriver_GetZeroTimeStamp(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID, Float64 *outSampleTime, UInt64 *outHostTime, UInt64 *outSeed)
{
    (void)inDriver; (void)inDeviceObjectID; (void)inClientID;
    if (outSampleTime == NULL || outHostTime == NULL || outSeed == NULL) { return kAudioHardwareIllegalOperationError; }

    UInt64 currentHostTime = mach_absolute_time();
    UInt64 anchor = gState.mAnchorHostTime;
    Float64 hostTicksPerFrame = gState.mHostTicksPerFrame;

    UInt64 elapsedTicks = currentHostTime >= anchor ? currentHostTime - anchor : 0;
    Float64 framesElapsed = (Float64)elapsedTicks / hostTicksPerFrame;
    UInt64 periodIndex = (UInt64)(framesElapsed / (Float64)kDevice_RingBufferFrames);
    Float64 zeroSampleTime = (Float64)(periodIndex * (UInt64)kDevice_RingBufferFrames);
    UInt64 zeroHostTime = anchor + (UInt64)(zeroSampleTime * hostTicksPerFrame);

    *outSampleTime = zeroSampleTime;
    *outHostTime = zeroHostTime;
    *outSeed = atomic_load_explicit(&gState.mClockSeed, memory_order_relaxed);
    return kAudioHardwareNoError;
}

static OSStatus AudioMixerVirtualDriver_WillDoIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID, UInt32 inOperationID, Boolean *outWillDo, Boolean *outWillDoInPlace)
{
    (void)inDriver; (void)inDeviceObjectID; (void)inClientID;
    Boolean willDo = inOperationID == kAudioServerPlugInIOOperationReadInput
                   || inOperationID == kAudioServerPlugInIOOperationWriteMix;
    if (outWillDo != NULL) { *outWillDo = willDo; }
    if (outWillDoInPlace != NULL) { *outWillDoInPlace = true; }
    return kAudioHardwareNoError;
}

static OSStatus AudioMixerVirtualDriver_BeginIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID, UInt32 inOperationID, UInt32 inIOBufferFrameSize, const AudioServerPlugInIOCycleInfo *inIOCycleInfo)
{
    (void)inDriver; (void)inDeviceObjectID; (void)inClientID; (void)inOperationID; (void)inIOBufferFrameSize; (void)inIOCycleInfo;
    return kAudioHardwareNoError;
}

static OSStatus AudioMixerVirtualDriver_EndIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID, UInt32 inOperationID, UInt32 inIOBufferFrameSize, const AudioServerPlugInIOCycleInfo *inIOCycleInfo)
{
    (void)inDriver; (void)inDeviceObjectID; (void)inClientID; (void)inOperationID; (void)inIOBufferFrameSize; (void)inIOCycleInfo;
    return kAudioHardwareNoError;
}

/* Copies `frameCount` interleaved stereo frames between `external` and the
 * ring buffer starting at ring-relative frame `ringStartFrame`, handling
 * wraparound. `toRing` selects the direction. RT-safe: fixed-size memcpy
 * only, no allocation, no locks. */
static void CopyRingFrames(float *external, UInt64 ringStartFrame, UInt32 frameCount, Boolean toRing)
{
    UInt32 startIndex = (UInt32)(ringStartFrame % kDevice_RingBufferFrames);
    UInt32 firstPart = kDevice_RingBufferFrames - startIndex;
    if (firstPart > frameCount) { firstPart = frameCount; }
    UInt32 secondPart = frameCount - firstPart;

    float *ringStart = gState.mRingBuffer + (size_t)startIndex * kDevice_ChannelCount;
    size_t firstBytes = (size_t)firstPart * kDevice_ChannelCount * sizeof(float);
    size_t secondBytes = (size_t)secondPart * kDevice_ChannelCount * sizeof(float);

    if (toRing)
    {
        memcpy(ringStart, external, firstBytes);
        if (secondPart > 0) { memcpy(gState.mRingBuffer, external + (size_t)firstPart * kDevice_ChannelCount, secondBytes); }
    }
    else
    {
        memcpy(external, ringStart, firstBytes);
        if (secondPart > 0) { memcpy(external + (size_t)firstPart * kDevice_ChannelCount, gState.mRingBuffer, secondBytes); }
    }
}

static OSStatus AudioMixerVirtualDriver_DoIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, AudioObjectID inStreamObjectID, UInt32 inClientID, UInt32 inOperationID, UInt32 inIOBufferFrameSize, const AudioServerPlugInIOCycleInfo *inIOCycleInfo, void *ioMainBuffer, void *ioSecondaryBuffer)
{
    (void)inDriver; (void)inDeviceObjectID; (void)inClientID; (void)ioSecondaryBuffer;
    if (ioMainBuffer == NULL || inIOCycleInfo == NULL || inIOBufferFrameSize == 0) { return kAudioHardwareNoError; }

    float *buffer = (float *)ioMainBuffer;

    if (inStreamObjectID == kObjectID_Stream_Output && inOperationID == kAudioServerPlugInIOOperationWriteMix)
    {
        /* AudioMixer's AUHAL output unit is writing the mixed bus into us. */
        Float64 sampleTime = inIOCycleInfo->mOutputTime.mSampleTime;
        UInt64 startFrame = (UInt64)(sampleTime < 0 ? 0 : sampleTime + 0.5);
        CopyRingFrames(buffer, startFrame, inIOBufferFrameSize, true);
        int64_t writeEnd = (int64_t)(startFrame + inIOBufferFrameSize);
        atomic_store_explicit(&gState.mWriteHighWaterMark, writeEnd, memory_order_release);
        return kAudioHardwareNoError;
    }

    if (inStreamObjectID == kObjectID_Stream_Input && inOperationID == kAudioServerPlugInIOOperationReadInput)
    {
        /* A conferencing app's AUHAL input unit is reading us as a microphone. */
        Float64 sampleTime = inIOCycleInfo->mInputTime.mSampleTime;
        UInt64 startFrame = (UInt64)(sampleTime < 0 ? 0 : sampleTime + 0.5);
        UInt64 requestEnd = startFrame + inIOBufferFrameSize;

        int64_t highWaterMark = atomic_load_explicit(&gState.mWriteHighWaterMark, memory_order_acquire);
        Boolean haveData = highWaterMark >= 0
                         && (int64_t)requestEnd <= highWaterMark
                         && (int64_t)requestEnd > highWaterMark - (int64_t)kDevice_RingBufferFrames;

        if (haveData)
        {
            CopyRingFrames(buffer, startFrame, inIOBufferFrameSize, false);
        }
        else
        {
            /* Nothing valid to hand back yet (AudioMixer isn't running, or
             * the reader has fallen more than a full ring behind): emit
             * deterministic silence rather than stale or uninitialized data. */
            memset(buffer, 0, (size_t)inIOBufferFrameSize * kDevice_ChannelCount * sizeof(float));
        }
        return kAudioHardwareNoError;
    }

    return kAudioHardwareNoError;
}
