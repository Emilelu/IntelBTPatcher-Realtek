//
//  IntelBTPatcher.cpp
//  IntelBTPatcher
//
//  Created by zxystd <zxystd@foxmail.com> on 2021/2/8.
//
#define __ACIDANTHERA_MAC_SDK 2600
#include <Headers/kern_api.hpp>
#include <Headers/kern_util.hpp>
#include <Headers/plugin_start.hpp>

#include "IntelBTPatcher.hpp"

static CIntelBTPatcher ibtPatcher;
static CIntelBTPatcher *callbackIBTPatcher = nullptr;
static long g_routeDevReqErr = -999;
static long g_routeAsyncIOErr = -999;
static long g_routeInitCfgErr = -999;
static long g_routeInitPipeErr = -999;
static int g_devReqTotal = 0;
static int g_asyncAll = 0;
static int g_leMetaStage = 0;
static int g_edlCleared = 0;
static int g_hciCmdCount = 0;
static unsigned int g_lastBm = 0;
static unsigned int g_lastReq = 0;

static const char *bootargOff[] {
    "-ibtcompatoff"
};

static const char *bootargDebug[] {
    "-ibtcompatdbg"
};

static const char *bootargBeta[] {
    "-ibtcompatbeta"
};

PluginConfiguration ADDPR(config) {
    xStringify(PRODUCT_NAME),
    parseModuleVersion(xStringify(MODULE_VERSION)),
    LiluAPI::AllowNormal | LiluAPI::AllowInstallerRecovery | LiluAPI::AllowSafeMode,
    bootargOff,
    arrsize(bootargOff),
    bootargDebug,
    arrsize(bootargDebug),
    bootargBeta,
    arrsize(bootargBeta),
    KernelVersion::MountainLion,
    KernelVersion::Tahoe,
    []() {
        IOLog("IntelBTPatcher: plugin start lambda entered\n");
        ibtPatcher.init();
        IOLog("IntelBTPatcher: init returned\n");
    }
};

static const char *IntelBTPatcher_IOBluetoothFamily[] { "/System/Library/Extensions/IOBluetoothFamily.kext/Contents/MacOS/IOBluetoothFamily" };

static KernelPatcher::KextInfo IntelBTPatcher_IOBluetoothInfo {
    "com.apple.iokit.IOBluetoothFamily",
    IntelBTPatcher_IOBluetoothFamily,
    1,
    {true, true},
    {},
    KernelPatcher::KextInfo::Unloaded
};

static const char *IntelBTPatcher_IOUSBHostFamily[] {
    "/System/Library/Extensions/IOUSBHostFamily.kext/Contents/MacOS/IOUSBHostFamily" };

static KernelPatcher::KextInfo IntelBTPatcher_IOUsbHostInfo {
    "com.apple.iokit.IOUSBHostFamily",
    IntelBTPatcher_IOUSBHostFamily,
    1,
    {true, true},
    {},
    KernelPatcher::KextInfo::Unloaded
};

void *CIntelBTPatcher::_hookPipeInstance = nullptr;
bool CIntelBTPatcher::_randomAddressInit = false;

bool CIntelBTPatcher::init()
{
    IOLog("IntelBTPatcher: init() called, kernel=%d\n", (int)getKernelVersion());
    DBGLOG(DRV_NAME, "%s", __PRETTY_FUNCTION__);
    callbackIBTPatcher = this;
    if (getKernelVersion() < KernelVersion::Monterey) {
        lilu.onKextLoadForce(&IntelBTPatcher_IOBluetoothInfo, 1,
        [](void *user, KernelPatcher &patcher, size_t index, mach_vm_address_t address, size_t size) {
            callbackIBTPatcher->processKext(patcher, index, address, size);
        }, this);
    } else {
        lilu.onKextLoadForce(&IntelBTPatcher_IOUsbHostInfo, 1,
        [](void *user, KernelPatcher &patcher, size_t index, mach_vm_address_t address, size_t size) {
            callbackIBTPatcher->processKext(patcher, index, address, size);
        }, this);
    }
    return true;
}

void CIntelBTPatcher::free()
{
    DBGLOG(DRV_NAME, "%s", __PRETTY_FUNCTION__);
}

void CIntelBTPatcher::processKext(KernelPatcher &patcher, size_t index, mach_vm_address_t address, size_t size)
{
    IOLog("IntelBTPatcher: processKext index=%lu usbLoadIndex=%lu btLoadIndex=%lu\n",
          (unsigned long)index,
          (unsigned long)IntelBTPatcher_IOUsbHostInfo.loadIndex,
          (unsigned long)IntelBTPatcher_IOBluetoothInfo.loadIndex);
    DBGLOG(DRV_NAME, "%s", __PRETTY_FUNCTION__);
    if (getKernelVersion() < KernelVersion::Monterey) {
        if (IntelBTPatcher_IOBluetoothInfo.loadIndex == index) {
            DBGLOG(DRV_NAME, "%s", IntelBTPatcher_IOBluetoothInfo.id);
            
            KernelPatcher::RouteRequest findQueueRequestRequest {
                "__ZN25IOBluetoothHostController17FindQueuedRequestEtP22BluetoothDeviceAddresstbPP21IOBluetoothHCIRequest",
                newFindQueueRequest,
                oldFindQueueRequest
            };
            patcher.routeMultiple(index, &findQueueRequestRequest, 1, address, size);
            if (patcher.getError() == KernelPatcher::Error::NoError) {
                DBGLOG(DRV_NAME, "routed %s", findQueueRequestRequest.symbol);
            } else {
                IOLog("IntelBTPatcher: failed to resolve %s, error = %d\n", findQueueRequestRequest.symbol, patcher.getError());
                patcher.clearError();
            }
            
        }
    } else {
        if (IntelBTPatcher_IOUsbHostInfo.loadIndex == index) {
            IOLog("IntelBTPatcher: %s\n", IntelBTPatcher_IOUsbHostInfo.id);
            
            KernelPatcher::RouteRequest hostDeviceRequest {
            "__ZN15IOUSBHostDevice13deviceRequestEP9IOServiceRN11StandardUSB13DeviceRequestEPvP18IOMemoryDescriptorRjP19IOUSBHostCompletionj",
                newHostDeviceRequest,
                oldHostDeviceRequest
            };
            patcher.routeMultiple(index, &hostDeviceRequest, 1, address, size);
            g_routeDevReqErr = (long)patcher.getError();
            if (patcher.getError() == KernelPatcher::Error::NoError) {
                IOLog("IntelBTPatcher: routed %s\n", hostDeviceRequest.symbol);
            } else {
                IOLog("IntelBTPatcher: failed to resolve %s, error = %d\n", hostDeviceRequest.symbol, patcher.getError());
                patcher.clearError();
            }

            KernelPatcher::RouteRequest asyncIORequest {
            "__ZN13IOUSBHostPipe2ioEP18IOMemoryDescriptorjP19IOUSBHostCompletionj",
                newAsyncIO,
                oldAsyncIO
            };
            patcher.routeMultiple(index, &asyncIORequest, 1, address, size);
            g_routeAsyncIOErr = (long)patcher.getError();
            if (patcher.getError() == KernelPatcher::Error::NoError) {
                IOLog("IntelBTPatcher: routed %s\n", asyncIORequest.symbol);
            } else {
                IOLog("IntelBTPatcher: failed to resolve %s, error = %d\n", asyncIORequest.symbol, patcher.getError());
                patcher.clearError();
            }

            // macOS 26.5+: third parameter became ConfigurationDescriptor (was SuperSpeedEndpointCompanionDescriptor)
            KernelPatcher::RouteRequest initPipeConfigRequest {
            "__ZN13IOUSBHostPipe28initWithDescriptorsAndOwnersEPKN11StandardUSB18EndpointDescriptorEPKNS0_23ConfigurationDescriptorEP22AppleUSBHostControllerP15IOUSBHostDeviceP18IOUSBHostInterfaceht",
                newInitPipeConfig,
                oldInitPipeConfig
            };
            patcher.routeMultiple(index, &initPipeConfigRequest, 1, address, size);
            g_routeInitCfgErr = (long)patcher.getError();
            if (patcher.getError() == KernelPatcher::Error::NoError) {
                IOLog("IntelBTPatcher: routed %s\n", initPipeConfigRequest.symbol);
            } else {
                IOLog("IntelBTPatcher: failed to resolve %s, error = %d\n", initPipeConfigRequest.symbol, patcher.getError());
                patcher.clearError();
            }

            KernelPatcher::RouteRequest initPipeRequest {
            "__ZN13IOUSBHostPipe28initWithDescriptorsAndOwnersEPKN11StandardUSB18EndpointDescriptorEPKNS0_37SuperSpeedEndpointCompanionDescriptorEP22AppleUSBHostControllerP15IOUSBHostDeviceP18IOUSBHostInterfaceht",
                newInitPipe,
                oldInitPipe
            };
            patcher.routeMultiple(index, &initPipeRequest, 1, address, size);
            g_routeInitPipeErr = (long)patcher.getError();
            if (patcher.getError() == KernelPatcher::Error::NoError) {
                IOLog("IntelBTPatcher: routed %s\n", initPipeRequest.symbol);
            } else {
                IOLog("IntelBTPatcher: failed to resolve %s, error = %d\n", initPipeRequest.symbol, patcher.getError());
                patcher.clearError();
            }
        }
    }
}

#pragma mark - For Bigsur-, patch unhandled 0x2019 opcode

#define HCI_OP_LE_START_ENCRYPTION 0x2019

IOReturn CIntelBTPatcher::newFindQueueRequest(void *that, unsigned short arg1, void *addr, unsigned short arg2, bool arg3, void **hciRequestPtr)
{
    IOReturn ret = FunctionCast(newFindQueueRequest, callbackIBTPatcher->oldFindQueueRequest)(that, arg1, addr, arg2, arg3, hciRequestPtr);
    if (ret != 0 && arg1 == HCI_OP_LE_START_ENCRYPTION) {
        ret = FunctionCast(newFindQueueRequest, callbackIBTPatcher->oldFindQueueRequest)(that, arg1, addr, 0xffff, arg3, hciRequestPtr);
        DBGLOG(DRV_NAME, "%s ret: %d arg1: 0x%04x arg2: 0x%04x arg3: %d ptr: %p", __FUNCTION__, ret, arg1, arg2, arg3, *hciRequestPtr);
    }
    return ret;
}

#pragma mark - For Monterey+ patch for intercept HCI REQ and RESP

StandardUSB::DeviceRequest randomAddressRequest;
// Hardcoded Random Address HCI Command
const uint8_t randomAddressHci[9] = {0x05, 0x20, 0x06, 0x94, 0x50, 0x64, 0xD0, 0x78, 0x6B}; 
IOBufferMemoryDescriptor *writeHCIDescriptor = nullptr;

#define MAX_HCI_BUF_LEN                 255
#define HCI_OP_RESET                    0x0c03
#define HCI_OP_LE_SET_SCAN_PARAM        0x200B
#define HCI_OP_LE_SET_SCAN_ENABLE       0x200C
#define HCI_OP_LE_READ_REMOTE_FEATURES  0x2016

int remoteReadSCount = 0;
int interceptedAsyncCount = 0;
static IOUSBHostDevice *g_btDevice = nullptr;
static int g_lrfSeen = 0;
static int g_asyncSeen = 0;
IOReturn CIntelBTPatcher::newHostDeviceRequest(void *that, IOService *provider, StandardUSB::DeviceRequest &request, void *data, IOMemoryDescriptor *descriptor, unsigned int &length, IOUSBHostCompletion *completion, unsigned int timeout)
{
    // Publish a marker on the real IOUSBHostDevice so we can verify from userland
    // (ioreg) that the deviceRequest hook actually fired.
    if (that != nullptr) {
        IOUSBHostDevice *dev = (IOUSBHostDevice *)that;
        if (dev->getProperty("IBTPDevReq") == nullptr)
            dev->setProperty("IBTPDevReq", OSData::withBytes("Y", 1));
        g_devReqTotal++;
        g_lastBm = request.bmRequestType;
        g_lastReq = request.bRequest;
        if (request.bmRequestType == 0x20)
            g_hciCmdCount++;
        if (g_btDevice != nullptr) {
            char sb[96];
            snprintf(sb, sizeof(sb), "total=%d hci=%d lastBm=0x%02x lastReq=0x%02x",
                     g_devReqTotal, g_hciCmdCount, g_lastBm, g_lastReq);
            g_btDevice->setProperty("IBTPDevReqStat", OSData::withBytes(sb, strlen(sb)));
        }
    }
    HciCommandHdr *hdr = nullptr;
    uint32_t hdrLen = 0;
    char hciBuf[MAX_HCI_BUF_LEN] = {0};
    
    if (data == nullptr) {
        if (descriptor != nullptr &&
            (getKernelVersion() < KernelVersion::Sequoia || !descriptor->prepare(kIODirectionOut))) {
            if (descriptor->getLength() > 0) {
                descriptor->readBytes(0, hciBuf, min(descriptor->getLength(), MAX_HCI_BUF_LEN));
                hdrLen = (uint32_t)min(descriptor->getLength(), MAX_HCI_BUF_LEN);
            }
            if (getKernelVersion() >= KernelVersion::Sequoia)
                descriptor->complete(kIODirectionOut);
        }
        hdr = (HciCommandHdr *)hciBuf;
        if (hdr->opcode == HCI_OP_LE_SET_SCAN_PARAM && hdr->data[5] == 0x1) {
            if (!_randomAddressInit) {
                randomAddressRequest.bmRequestType = makeDeviceRequestbmRequestType(kRequestDirectionOut, kRequestTypeClass, kRequestRecipientInterface);
                randomAddressRequest.bRequest = 0xE0;
                randomAddressRequest.wIndex = 0;
                randomAddressRequest.wValue = 0;
                randomAddressRequest.wLength = 9;
                length = 9;
                if (writeHCIDescriptor == nullptr)
                    writeHCIDescriptor = IOBufferMemoryDescriptor::withBytes(randomAddressHci, 9, kIODirectionInOut);
                writeHCIDescriptor->prepare(kIODirectionInOut);
                IOReturn ret = FunctionCast(newHostDeviceRequest, callbackIBTPatcher->oldHostDeviceRequest)(that, provider, randomAddressRequest, nullptr, writeHCIDescriptor, length, nullptr, timeout);
                writeHCIDescriptor->complete(kIODirectionInOut);
                const char *randAddressDump = _hexDumpHCIData((uint8_t *)randomAddressHci, 9);
                if (randAddressDump) {
                    IOLog("IntelBTPatcher: [PATCH] Sending Random Address HCI %d %s\n", ret, randAddressDump);
                    IOFree((void *)randAddressDump, 9 * 3 + 1);
                }
                _randomAddressInit = true;
                IOLog("IntelBTPatcher: [PATCH] Resend LE SCAN PARAM HCI %d\n", ret);
            }
        } else if (hdr->opcode == HCI_OP_LE_READ_REMOTE_FEATURES) {
            g_lrfSeen++;
            if (g_btDevice != nullptr) {
                char b[16];
                snprintf(b, sizeof(b), "%d", g_lrfSeen);
                g_btDevice->setProperty("IBTPReqLRF", OSData::withBytes(b, strlen(b)));
            }
            // #514: send TWO extra reads -> two duplicate 0x04 events to rewrite
            // (1st dup -> fake PHY Update Complete, 2nd dup -> fake LE Data Length Change).
            // Realtek only returns ONE real LE Read Remote Features Complete event.
            // Reset (not +=) so the counter cannot grow unbounded and block the rewrite.
            remoteReadSCount = 2;
            g_leMetaStage = 0;
            FunctionCast(newHostDeviceRequest, callbackIBTPatcher->oldHostDeviceRequest)(that, provider, request, nullptr, descriptor, length, nullptr, timeout);
            FunctionCast(newHostDeviceRequest, callbackIBTPatcher->oldHostDeviceRequest)(that, provider, request, nullptr, descriptor, length, nullptr, timeout);
        }
    } else {
        hdr = (HciCommandHdr *)data;
        hdrLen = request.wLength - 3;
    }
    if (hdr) {
        // HCI reset, we need to send Random address again
        if (hdr->opcode == HCI_OP_RESET)
            _randomAddressInit = false;
#if DEBUG
        DBGLOG(DRV_NAME, "[%s] bRequest: 0x%x direction: %s type: %s recipient: %s wValue: 0x%02x wIndex: 0x%02x opcode: 0x%04x len: %d length: %d async: %d", provider->getName(), request.bRequest, requestDirectionNames[(request.bmRequestType & kDeviceRequestDirectionMask) >> kDeviceRequestDirectionPhase], requestRecipientNames[(request.bmRequestType & kDeviceRequestRecipientMask) >> kDeviceRequestRecipientPhase], requestTypeNames[(request.bmRequestType & kDeviceRequestTypeMask) >> kDeviceRequestTypePhase], request.wValue, request.wIndex, hdr->opcode, hdr->len, request.wLength, completion != nullptr);
        if (hdrLen) {
            const char *dump = _hexDumpHCIData((uint8_t *)hdr, hdrLen);
            if (dump) {
                DBGLOG(DRV_NAME, "[Request]: %s", dump);
                IOFree((void *)dump, hdrLen * 3 + 1);
            }
        }
#endif
    }
    return FunctionCast(newHostDeviceRequest, callbackIBTPatcher->oldHostDeviceRequest)(that, provider, request, data, descriptor, length, completion, timeout);
}

#define HCI_EVT_LE_META                               0x3E
#define HCI_EVT_LE_META_READ_REMOTE_FEATURES_COMPLETE 0x04

uint8_t fakePhyUpdateCompleteEvent[8] = {0x3E, 0x06, 0x0C, 0x00, 0x00, 0x00, 0x02, 0x02};
// #514: LE Data Length Change (LE Meta subevent 0x07, no status byte -> handle at [3][4]).
// bluetoothd stalls at LE_READY_WAIT_FOR_LENGTH after PHY until it sees this. 27 octets / 328us tx+rx.
// Made by Claude.
uint8_t fakeDataLengthChangeEvent[13] = {0x3E, 0x0B, 0x07, 0x00, 0x00, 0x1B, 0x00, 0x48, 0x01, 0x1B, 0x00, 0x48, 0x01};
//uint8_t remoteFeaturesStatus[6] = {0x0F, 0x04, 0x00, 0x01, 0x16, 0x20};

static void asyncIOCompletion(void* owner, void* parameter, IOReturn status, uint32_t bytesTransferred)
{
    AsyncOwnerData *asyncOwner = (AsyncOwnerData *)owner;
    IOMemoryDescriptor* dataBuffer = asyncOwner->dataBuffer;
    // #514 3-stage rewrite of the repeated LE Read Remote Features Complete (0x04) events:
    //   stage 0 = the real one (pass through), 1 = rewrite to fake PHY Update Complete,
    //   2 = rewrite to fake LE Data Length Change (clears bluetoothd's LE_READY_WAIT_FOR_LENGTH).
    uint32_t allocLen = bytesTransferred;

    if (dataBuffer && bytesTransferred) {
        void *buffer = IOMalloc(allocLen);
        if (buffer) {
            if (dataBuffer->getLength() > 0 && (getKernelVersion() < KernelVersion::Sequoia || !dataBuffer->prepare(kIODirectionInOut))) {
                dataBuffer->readBytes(0, buffer, allocLen);
                HciEventHdr *hdr = (HciEventHdr *)buffer;
                // Experimental fix: hide LE Data Packet Length Extension (bit5) from
                // bluetoothd in the LE Read Local Supported Features Command Complete.
                // If the controller does not advertise EDL, bluetoothd should not enter
                // LE_READY_WAIT_FOR_LENGTH at all.
                if (hdr->evt == 0x0E && hdr->len >= 12 &&
                    hdr->data[1] == 0x03 && hdr->data[2] == 0x20 &&
                    (hdr->data[4] & 0x20) != 0) {
                    hdr->data[4] &= (uint8_t)~0x20;
                    dataBuffer->writeBytes(0, buffer, allocLen);
                    g_edlCleared++;
                    if (g_btDevice != nullptr) {
                        char eb[16];
                        snprintf(eb, sizeof(eb), "%d", g_edlCleared);
                        g_btDevice->setProperty("IBTPEDLClear", OSData::withBytes(eb, strlen(eb)));
                    }
                }
                if (hdr->evt == HCI_EVT_LE_META && hdr->data[0] == HCI_EVT_LE_META_READ_REMOTE_FEATURES_COMPLETE) {
                    if (g_leMetaStage == 0) {
                        g_leMetaStage = 1;            // real features complete -> pass through
                    } else if (g_leMetaStage == 1) {  // 1st duplicate -> fake PHY Update Complete
                        fakePhyUpdateCompleteEvent[4] = hdr->data[2];
                        fakePhyUpdateCompleteEvent[5] = hdr->data[3];
                        dataBuffer->writeBytes(0, fakePhyUpdateCompleteEvent, 8);
                        bytesTransferred = 8;
                        g_leMetaStage = 2;
                        remoteReadSCount--;
                    } else {                        // 2nd duplicate -> fake LE Data Length Change
                        fakeDataLengthChangeEvent[3] = hdr->data[2];
                        fakeDataLengthChangeEvent[4] = hdr->data[3];
                        dataBuffer->writeBytes(0, fakeDataLengthChangeEvent, 13);
                        bytesTransferred = 13;
                        g_leMetaStage = 0;
                        remoteReadSCount--;
                    }
                }
                if (getKernelVersion() >= KernelVersion::Sequoia) dataBuffer->complete(kIODirectionInOut);
            }
            IOFree(buffer, allocLen);
        }
    }
    if (asyncOwner->action)
        asyncOwner->action(asyncOwner->owner, parameter, status, bytesTransferred);
    delete asyncOwner;
}

IOReturn CIntelBTPatcher::
newAsyncIO(void *that, IOMemoryDescriptor* dataBuffer, uint32_t bytesTransferred, IOUSBHostCompletion* completion, uint32_t completionTimeoutMs)
{
    g_asyncAll++;
    if (g_btDevice != nullptr && (g_asyncAll % 50) == 1) {
        char ab[48];
        snprintf(ab, sizeof(ab), "asyncAll=%d lrf=%d hit=%d", g_asyncAll, g_lrfSeen, interceptedAsyncCount);
        g_btDevice->setProperty("IBTPAsyncAll", OSData::withBytes(ab, strlen(ab)));
    }
    if (remoteReadSCount > 0) {
        g_asyncSeen++;
        if (g_btDevice != nullptr) {
            char b[16];
            snprintf(b, sizeof(b), "%d", g_asyncSeen);
            g_btDevice->setProperty("IBTPAsyncSeen", OSData::withBytes(b, strlen(b)));
        }
    }
    if (remoteReadSCount > 0 && that == _hookPipeInstance && completion) {
        interceptedAsyncCount++;
        if (g_btDevice != nullptr)
            g_btDevice->setProperty("IBTPAsyncHit", OSData::withBytes("Y", 1));
        AsyncOwnerData *ownerData = new AsyncOwnerData;
        ownerData->action = completion->action;
        ownerData->owner = completion->owner;
        ownerData->dataBuffer = dataBuffer;
        completion->action = asyncIOCompletion;
        completion->owner = ownerData;
    }
    return FunctionCast(newAsyncIO, callbackIBTPatcher->oldAsyncIO)(that, dataBuffer, bytesTransferred, completion, completionTimeoutMs);
}

#define VENDOR_USB_INTEL 0x8087
// Support Realtek USB Bluetooth combo radios (e.g. RTL8821CE in HP 15s) with
// the same LE HID fix: they suffer the identical missing LE Data Length Change.
#define VENDOR_USB_REALTEK 0x0BDA

void CIntelBTPatcher::captureIntelInterruptPipe(void *that, StandardUSB::EndpointDescriptor const *descriptor, IOUSBHostDevice *device)
{
    if (!device)
        return;
    const StandardUSB::DeviceDescriptor *deviceDescriptor = device->getDeviceDescriptor();
    if (deviceDescriptor && (deviceDescriptor->idVendor == VENDOR_USB_INTEL || deviceDescriptor->idVendor == VENDOR_USB_REALTEK)) {
        bool isRealtek = (deviceDescriptor->idVendor == VENDOR_USB_REALTEK);
        if (isRealtek)
            IOLog("IntelBTPatcher: [Realtek] vendor 0x0BDA matched, idProduct=0x%04x (%s)\n", deviceDescriptor->idProduct, device->getName());
        uint8_t epType = StandardUSB::getEndpointType(descriptor);
        if (epType == kIOUSBEndpointTypeInterrupt) {
            CIntelBTPatcher::_hookPipeInstance = that;
            g_btDevice = device;
            {
                char rb[64];
                snprintf(rb, sizeof(rb), "dev=%ld async=%ld initCfg=%ld initPipe=%ld",
                         g_routeDevReqErr, g_routeAsyncIOErr, g_routeInitCfgErr, g_routeInitPipeErr);
                device->setProperty("IBTPRouteErr", OSData::withBytes(rb, strlen(rb)));
            }
            if (device->getProperty("IBTPPipeCaptured") == nullptr) {
                device->setProperty("IBTPPipeCaptured", OSData::withBytes("Y", 1));
                char pbuf[32];
                snprintf(pbuf, sizeof(pbuf), "%lx", (unsigned long)(uintptr_t)that);
                device->setProperty("IBTPPipeAddr", OSData::withBytes(pbuf, strlen(pbuf)));
            }
            if (isRealtek)
                IOLog("IntelBTPatcher: [Realtek] interrupt pipe captured on %s, LE Data Length Change fix armed\n", device->getName());
        }
    }
}

int CIntelBTPatcher::
newInitPipe(void *that, StandardUSB::EndpointDescriptor const *descriptor, StandardUSB::SuperSpeedEndpointCompanionDescriptor const *superDescriptor, AppleUSBHostController *controller, IOUSBHostDevice *device, IOUSBHostInterface *interface, unsigned char a7, unsigned short a8)
{
    int ret = FunctionCast(newInitPipe, callbackIBTPatcher->oldInitPipe)(that, descriptor, superDescriptor, controller, device, interface, a7, a8);
    captureIntelInterruptPipe(that, descriptor, device);
    return ret;
}

int CIntelBTPatcher::
newInitPipeConfig(void *that, StandardUSB::EndpointDescriptor const *descriptor, StandardUSB::ConfigurationDescriptor const *configDescriptor, AppleUSBHostController *controller, IOUSBHostDevice *device, IOUSBHostInterface *interface, unsigned char a7, unsigned short a8)
{
    int ret = FunctionCast(newInitPipeConfig, callbackIBTPatcher->oldInitPipeConfig)(that, descriptor, configDescriptor, controller, device, interface, a7, a8);
    captureIntelInterruptPipe(that, descriptor, device);
    return ret;
}
