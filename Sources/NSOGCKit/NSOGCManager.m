#import "NSOGCInternal.h"

#import <os/lock.h>
#import <os/log.h>

static NSString *const kKnownControllersKey = @"NSOGCKnownControllers";
static NSString *const kControlServiceUUID = @"00C5AF5D-1964-4E30-8F51-1956F96BD280";
static NSString *const kNintendoServiceUUID = @"AB7DE9BE-89FE-49AD-828F-118F09DF7FD0";

// After a failed setup, the same controller is left alone this long before
// another connection attempt.
static const CFTimeInterval kRetryBackoff = 5.0;

static NSString *NSOGCStateName(CBManagerState state) {
  switch (state) {
    case CBManagerStatePoweredOn: return @"on";
    case CBManagerStatePoweredOff: return @"off";
    case CBManagerStateUnauthorized: return @"not allowed for this app";
    case CBManagerStateUnsupported: return @"unsupported";
    case CBManagerStateResetting: return @"resetting";
    default: return @"unknown";
  }
}

static NSString *NSOGCHexData(NSData *data) {
  if (data.length == 0)
    return @"none";
  const uint8_t *bytes = data.bytes;
  NSMutableString *text = [NSMutableString stringWithCapacity:data.length * 3];
  for (NSUInteger i = 0; i < data.length; i++)
    [text appendFormat:i == 0 ? @"%02X" : @" %02X", bytes[i]];
  return text;
}

@interface NSOGCManager () <CBCentralManagerDelegate>
@end

@implementation NSOGCManager {
  dispatch_queue_t _queue;
  os_log_t _osLog;

  // Bluetooth queue only.
  CBCentralManager *_central;
  BOOL _wantsRunning;
  NSMutableDictionary<NSUUID *, NSOGCController *> *_tracked;  // connecting or connected
  NSMutableSet<NSUUID *> *_reported;                          // advertisements already logged
  NSMutableDictionary<NSUUID *, NSNumber *> *_lastFailure;

  // Read from any thread.
  os_unfair_lock _lock;
  NSArray<NSOGCController *> *_readyControllers;
  BOOL _running;
  void (^_logHandler)(NSString *);
}

+ (NSOGCManager *)sharedManager {
  static NSOGCManager *manager;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    manager = [[NSOGCManager alloc] init];
  });
  return manager;
}

- (instancetype)init {
  self = [super init];
  if (self) {
    _queue = dispatch_queue_create("nsogc.bluetooth", DISPATCH_QUEUE_SERIAL);
    _osLog = os_log_create("nsogc", "bluetooth");
    _callbackQueue = dispatch_get_main_queue();
    _maximumControllers = 4;
    _tracked = [NSMutableDictionary dictionary];
    _reported = [NSMutableSet set];
    _lastFailure = [NSMutableDictionary dictionary];
    _lock = OS_UNFAIR_LOCK_INIT;
    _readyControllers = @[];
  }
  return self;
}

#pragma mark - Public

- (NSArray<NSOGCController *> *)controllers {
  os_unfair_lock_lock(&_lock);
  NSArray<NSOGCController *> *controllers = _readyControllers;
  os_unfair_lock_unlock(&_lock);
  return controllers;
}

- (BOOL)isRunning {
  os_unfair_lock_lock(&_lock);
  BOOL running = _running;
  os_unfair_lock_unlock(&_lock);
  return running;
}

- (void (^)(NSString *))logHandler {
  os_unfair_lock_lock(&_lock);
  void (^handler)(NSString *) = _logHandler;
  os_unfair_lock_unlock(&_lock);
  return handler;
}

- (void)setLogHandler:(void (^)(NSString *))logHandler {
  void (^copy)(NSString *) = [logHandler copy];
  os_unfair_lock_lock(&_lock);
  _logHandler = copy;
  os_unfair_lock_unlock(&_lock);
}

- (void)start {
  dispatch_async(_queue, ^{
    if (self->_wantsRunning)
      return;
    self->_wantsRunning = YES;
    [self setRunning:YES];
    [self log:@"starting"];
    if (self->_central == nil)
      self->_central = [[CBCentralManager alloc]
          initWithDelegate:self
                     queue:self->_queue
                   options:@{CBCentralManagerOptionShowPowerAlertKey : @NO}];
    else if (self->_central.state == CBManagerStatePoweredOn)
      [self resume];
  });
}

- (void)stop {
  dispatch_async(_queue, ^{
    if (!self->_wantsRunning)
      return;
    self->_wantsRunning = NO;
    [self setRunning:NO];
    if (self->_central.state == CBManagerStatePoweredOn)
      [self->_central stopScan];
    for (NSOGCController *controller in self->_tracked.allValues)
      [self->_central cancelPeripheralConnection:controller.peripheral];
    [self log:@"stopped"];
  });
}

- (void)forgetControllers {
  dispatch_async(_queue, ^{
    [NSUserDefaults.standardUserDefaults removeObjectForKey:kKnownControllersKey];
    [self log:@"forgot remembered controllers"];
  });
}

#pragma mark - Internal (Bluetooth queue)

- (void)setRunning:(BOOL)running {
  os_unfair_lock_lock(&_lock);
  _running = running;
  os_unfair_lock_unlock(&_lock);
}

- (void)log:(NSString *)format, ... {
  va_list arguments;
  va_start(arguments, format);
  NSString *line = [[NSString alloc] initWithFormat:format arguments:arguments];
  va_end(arguments);
  os_log(_osLog, "%{public}@", line);
  void (^handler)(NSString *) = self.logHandler;
  if (handler != nil)
    dispatch_async(_callbackQueue, ^{ handler(line); });
}

- (NSArray<NSUUID *> *)knownIdentifiers {
  NSMutableArray<NSUUID *> *identifiers = [NSMutableArray array];
  for (NSString *string in [NSUserDefaults.standardUserDefaults stringArrayForKey:kKnownControllersKey]) {
    NSUUID *identifier = [[NSUUID alloc] initWithUUIDString:string];
    if (identifier != nil)
      [identifiers addObject:identifier];
  }
  return identifiers;
}

- (void)rememberIdentifier:(NSUUID *)identifier {
  NSMutableArray<NSString *> *known =
      [[NSUserDefaults.standardUserDefaults stringArrayForKey:kKnownControllersKey] mutableCopy]
          ?: [NSMutableArray array];
  if (![known containsObject:identifier.UUIDString]) {
    [known addObject:identifier.UUIDString];
    [NSUserDefaults.standardUserDefaults setObject:known forKey:kKnownControllersKey];
  }
}

- (NSUInteger)readyCount {
  NSUInteger count = 0;
  for (NSOGCController *controller in _tracked.allValues)
    if (controller.status == NSOGCControllerStatusReady)
      count++;
  return count;
}

- (void)refreshReadyControllers {
  NSMutableArray<NSOGCController *> *ready = [NSMutableArray array];
  for (NSOGCController *controller in _tracked.allValues)
    if (controller.status == NSOGCControllerStatusReady)
      [ready addObject:controller];
  [ready sortUsingComparator:^NSComparisonResult(NSOGCController *a, NSOGCController *b) {
    return [@(a.playerIndex) compare:@(b.playerIndex)];
  }];
  os_unfair_lock_lock(&_lock);
  _readyControllers = [ready copy];
  os_unfair_lock_unlock(&_lock);
}

- (void)resume {
  if (!_wantsRunning || _central.state != CBManagerStatePoweredOn)
    return;
  // A pending connection to a remembered controller completes whenever it is
  // in range and connectable, with no scan needed.
  NSArray<NSUUID *> *known = [self knownIdentifiers];
  if (known.count > 0)
    for (CBPeripheral *peripheral in [_central retrievePeripheralsWithIdentifiers:known])
      [self connect:peripheral reason:@"remembered"];
  NSArray<CBUUID *> *services = @[ [CBUUID UUIDWithString:kNintendoServiceUUID],
                                   [CBUUID UUIDWithString:kControlServiceUUID] ];
  for (CBPeripheral *peripheral in [_central retrieveConnectedPeripheralsWithServices:services])
    [self connect:peripheral reason:@"already connected to the system"];
  [self updateScanning];
}

- (void)updateScanning {
  if (_central.state != CBManagerStatePoweredOn)
    return;
  BOOL wantsScan = _wantsRunning && [self readyCount] < _maximumControllers;
  if (wantsScan && !_central.isScanning) {
    [_central scanForPeripheralsWithServices:nil
                                     options:@{CBCentralManagerScanOptionAllowDuplicatesKey : @YES}];
    [self log:@"scanning: press SYNC on the controller"];
  } else if (!wantsScan && _central.isScanning) {
    [_central stopScan];
    [self log:@"scanning stopped"];
  }
}

- (void)connect:(CBPeripheral *)peripheral reason:(NSString *)reason {
  if (_tracked[peripheral.identifier] != nil)
    return;
  NSOGCController *controller = [[NSOGCController alloc] initWithPeripheral:peripheral
                                                                    manager:self
                                                                      queue:_queue
                                                              callbackQueue:_callbackQueue];
  _tracked[peripheral.identifier] = controller;
  [self log:@"connecting to %@ (%@)", controller.name, reason];
  [_central connectPeripheral:peripheral options:nil];
}

- (void)notifyDelegate:(void (^)(id<NSOGCManagerDelegate> delegate))call selector:(SEL)selector {
  id<NSOGCManagerDelegate> delegate = self.delegate;
  if (delegate == nil || ![delegate respondsToSelector:selector])
    return;
  dispatch_async(_callbackQueue, ^{ call(delegate); });
}

- (void)controllerDidBecomeReady:(NSOGCController *)controller {
  [self rememberIdentifier:controller.identifier];
  [_lastFailure removeObjectForKey:controller.identifier];
  NSMutableIndexSet *used = [NSMutableIndexSet indexSet];
  for (NSOGCController *other in _tracked.allValues)
    if (other != controller && other.status == NSOGCControllerStatusReady)
      [used addIndex:(NSUInteger)other.playerIndex];
  NSInteger player = 0;
  while ([used containsIndex:(NSUInteger)player])
    player++;
  [controller assignPlayerIndex:player];
  [self refreshReadyControllers];
  [self log:@"%@ ready as player %ld", controller.name, (long)player + 1];
  [self notifyDelegate:^(id<NSOGCManagerDelegate> delegate) {
    [delegate manager:self didConnectController:controller];
  } selector:@selector(manager:didConnectController:)];
  [self updateScanning];
}

- (void)controllerDidFail:(NSOGCController *)controller reason:(NSString *)reason {
  [self log:@"%@: setup failed: %@", controller.name, reason];
  _lastFailure[controller.identifier] = @(CFAbsoluteTimeGetCurrent());
  [_central cancelPeripheralConnection:controller.peripheral];
}

#pragma mark - CBCentralManagerDelegate

- (void)centralManagerDidUpdateState:(CBCentralManager *)central {
  [self log:@"Bluetooth %@", NSOGCStateName(central.state)];
  if (central.state == CBManagerStateUnauthorized)
    [self log:@"allow Bluetooth for this app in Settings, then open it again"];
  BOOL available = central.state == CBManagerStatePoweredOn;
  [self notifyDelegate:^(id<NSOGCManagerDelegate> delegate) {
    [delegate manager:self bluetoothAvailabilityDidChange:available];
  } selector:@selector(manager:bluetoothAvailabilityDidChange:)];
  if (available) {
    [self resume];
  } else {
    // Bluetooth went away: every connection is gone with it.
    for (NSOGCController *controller in _tracked.allValues)
      [controller didDisconnect];
    [_tracked removeAllObjects];
    [self refreshReadyControllers];
  }
}

- (void)centralManager:(CBCentralManager *)central
    didDiscoverPeripheral:(CBPeripheral *)peripheral
        advertisementData:(NSDictionary<NSString *, id> *)advertisementData
                     RSSI:(NSNumber *)RSSI {
  if (_tracked[peripheral.identifier] != nil || !_wantsRunning)
    return;
  NSData *manufacturer = advertisementData[CBAdvertisementDataManufacturerDataKey];
  NSString *name = advertisementData[CBAdvertisementDataLocalNameKey] ?: peripheral.name;
  const uint8_t *bytes = manufacturer.bytes;
  uint16_t company = manufacturer.length >= 2 ? (uint16_t)(bytes[0] | (bytes[1] << 8)) : 0;
  BOOL nintendo = company == NSOGC_COMPANY_ID_SWITCH2 || company == NSOGC_COMPANY_ID_CLASSIC;
  // The controller's GAP name is literally "DeviceName".
  BOOL nameMatches = [name isEqualToString:@"DeviceName"] ||
                     [name localizedCaseInsensitiveContainsString:@"GameCube"];
  if (!nintendo && !nameMatches)
    return;

  uint16_t product = 0;
  BOOL matches = nintendo
                     ? nsogc_advertisement_matches(manufacturer.bytes, manufacturer.length, &product)
                     : manufacturer.length == 0;
  if (![_reported containsObject:peripheral.identifier]) {
    [_reported addObject:peripheral.identifier];
    [self log:@"found %@ (RSSI %@, product 0x%04X, manufacturer data %@)",
              name ?: @"an unnamed device", RSSI, product, NSOGCHexData(manufacturer)];
    if (!matches)
      [self log:@"not the GameCube controller, ignored"];
  }
  if (!matches)
    return;
  if ([advertisementData[CBAdvertisementDataIsConnectable] isEqual:@NO])
    return;
  NSNumber *failure = _lastFailure[peripheral.identifier];
  if (failure != nil && CFAbsoluteTimeGetCurrent() - failure.doubleValue < kRetryBackoff)
    return;
  if ([self readyCount] >= _maximumControllers)
    return;
  [self connect:peripheral reason:@"advertising"];
}

- (void)centralManager:(CBCentralManager *)central didConnectPeripheral:(CBPeripheral *)peripheral {
  NSOGCController *controller = _tracked[peripheral.identifier];
  if (controller == nil) {
    [central cancelPeripheralConnection:peripheral];
    return;
  }
  [controller didConnect];
}

- (void)centralManager:(CBCentralManager *)central
    didFailToConnectPeripheral:(CBPeripheral *)peripheral
                         error:(NSError *)error {
  NSOGCController *controller = _tracked[peripheral.identifier];
  [self log:@"could not connect to %@: %@", controller.name ?: peripheral.identifier.UUIDString,
            error.localizedDescription ?: @"unknown error"];
  [_tracked removeObjectForKey:peripheral.identifier];
  _lastFailure[peripheral.identifier] = @(CFAbsoluteTimeGetCurrent());
  [self updateScanning];
}

- (void)centralManager:(CBCentralManager *)central
    didDisconnectPeripheral:(CBPeripheral *)peripheral
                      error:(NSError *)error {
  NSOGCController *controller = _tracked[peripheral.identifier];
  if (controller == nil)
    return;
  BOOL wasReady = controller.status == NSOGCControllerStatusReady;
  [controller didDisconnect];
  [_tracked removeObjectForKey:peripheral.identifier];
  [self log:@"%@ disconnected%@", controller.name,
            error ? [@": " stringByAppendingString:error.localizedDescription] : @""];
  if ([error.domain isEqualToString:CBErrorDomain] &&
      error.code == CBErrorPeerRemovedPairingInformation)
    [self log:@"the controller dropped its pairing: forget it in Settings > Bluetooth, "
              @"then press SYNC again"];
  if (wasReady) {
    [self refreshReadyControllers];
    [self notifyDelegate:^(id<NSOGCManagerDelegate> delegate) {
      [delegate manager:self didDisconnectController:controller];
    } selector:@selector(manager:didDisconnectController:)];
  }
  // Wait for it to come back: a pending connection costs nothing.
  if (_wantsRunning && [[self knownIdentifiers] containsObject:peripheral.identifier])
    [self connect:peripheral reason:@"reconnecting when it is back"];
  [self updateScanning];
}

@end
