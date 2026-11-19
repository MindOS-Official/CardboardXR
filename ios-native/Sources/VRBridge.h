#pragma once

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

#ifdef __cplusplus
extern "C" {
#endif

constexpr int kMaxParsecStreams = 2;
constexpr int kMaxWebMonitors = 5;

int VRParsecInit(void);
void VRParsecDestroy(void);
int VRParsecConnect(const char *sessionId, const char *peerId, int width, int height, int useH265);
void VRParsecDisconnect(void);
int VRParsecGetStatus(int *outWidth, int *outHeight, int *outNetworkFailure);
void VRParsecSetSecondStreamEnabled(int enabled);
UIImage *VRParsecPollStreamImage(int streamIndex, int timeoutMs);
void VRParsecSendStreamMousePosition(int streamIndex, int x, int y);
void VRParsecSendMouseButton(int button, int pressed);
void VRParsecSendMouseWheel(int deltaX, int deltaY);
void VRParsecSendKey(int usbHidKeyCode, int pressed);
void VRParsecSetMuted(int muted);

void VRKeychainSave(const char *key, const char *value);
NSString *VRKeychainLoad(const char *key);
void VRKeychainDelete(const char *key);

void VRWebInitSlot(int slot, int width, int height, const char *initialUrl);
void VRWebDestroyAll(void);
void VRWebLoadUrlSlot(int slot, const char *url);
void VRWebGoBackSlot(int slot);
void VRWebGoForwardSlot(int slot);
void VRWebReloadSlot(int slot);
UIImage *VRWebSnapshotSlot(int slot);
void VRWebClickSlot(int slot, float normX, float normY);
void VRWebScrollSlot(int slot, float normX, float normY, float deltaY);
void VRWebTypeKeySlot(int slot, const char *text, int isBackspace, int isEnter);
NSString *VRWebGetUrlSlot(int slot);
int VRWebIsLoadingSlot(int slot);

#ifdef __cplusplus
}
#endif
