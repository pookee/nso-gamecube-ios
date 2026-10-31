// Interfaces shared by NSOGCManager and NSOGCController only.

#import <CoreBluetooth/CoreBluetooth.h>

#import "NSOGCController.h"
#import "NSOGCManager.h"

NS_ASSUME_NONNULL_BEGIN

@interface NSOGCManager ()
// Both run on the manager's Bluetooth queue.
- (void)controllerDidBecomeReady:(NSOGCController *)controller;
- (void)controllerDidFail:(NSOGCController *)controller reason:(NSString *)reason;
- (void)log:(NSString *)format, ... NS_FORMAT_FUNCTION(1, 2);
@end

@interface NSOGCController () <CBPeripheralDelegate>
@property(nonatomic, readonly) CBPeripheral *peripheral;

// Everything below runs on `queue`, the manager's Bluetooth queue.
- (instancetype)initWithPeripheral:(CBPeripheral *)peripheral
                           manager:(NSOGCManager *)manager
                             queue:(dispatch_queue_t)queue
                     callbackQueue:(dispatch_queue_t)callbackQueue NS_DESIGNATED_INITIALIZER;
- (void)didConnect;
- (void)didDisconnect;
- (void)assignPlayerIndex:(NSInteger)playerIndex;
@end

NS_ASSUME_NONNULL_END
