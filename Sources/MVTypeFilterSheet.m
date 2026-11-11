#import "MVTypeFilterSheet.h"
#import "MVTheme.h"
#import "MVLang.h"

@interface MVTypeFilterSheet () <UITableViewDataSource, UITableViewDelegate>
@property (nonatomic, copy) NSArray<NSArray *> *types;
@property (nonatomic, copy, nullable) NSString *selected;
@end

@implementation MVTypeFilterSheet {
    UITableView *_table;
}

- (instancetype)initWithTypes:(NSArray<NSArray *> *)types selected:(NSString *)category {
    if ((self = [super initWithNibName:nil bundle:nil])) {
        _types = [types copy];
        _selected = [category copy];
    }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [MVTheme card];
    self.title = [MVLang t:@"Filter by type"];

    _table = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStyleInsetGrouped];
    _table.translatesAutoresizingMaskIntoConstraints = NO;
    _table.backgroundColor = UIColor.clearColor;
    _table.dataSource = self;
    _table.delegate = self;
    _table.rowHeight = 52;
    [_table registerClass:UITableViewCell.class forCellReuseIdentifier:@"cell"];
    [self.view addSubview:_table];
    [NSLayoutConstraint activateConstraints:@[
        [_table.topAnchor constraintEqualToAnchor:self.view.topAnchor],
        [_table.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [_table.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [_table.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
    ]];

    if (@available(iOS 15.0, *)) {
        UISheetPresentationController *sheet = self.sheetPresentationController;
        sheet.detents = @[[UISheetPresentationControllerDetent mediumDetent],
                          [UISheetPresentationControllerDetent largeDetent]];
        sheet.prefersGrabberVisible = YES;
        sheet.preferredCornerRadius = 24;
    }
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return (NSInteger)self.types.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"cell" forIndexPath:indexPath];
    NSArray *entry = self.types[indexPath.row];
    NSString *name = entry[0];
    NSString *symbol = entry[1];
    NSInteger count = [entry[2] integerValue];
    NSString *category = entry.count > 3 ? entry[3] : nil;

    UIListContentConfiguration *content = cell.defaultContentConfiguration;
    content.text = name;
    content.textProperties.color = [MVTheme text];
    content.secondaryText = count > 0 ? [NSString stringWithFormat:@"%ld", (long)count] : nil;
    content.secondaryTextProperties.color = [MVTheme secondaryText];
    content.image = [UIImage systemImageNamed:symbol];
    content.imageProperties.tintColor = [MVTheme accent];
    content.imageProperties.maximumSize = CGSizeMake(24, 24);
    cell.contentConfiguration = content;
    cell.backgroundColor = [MVTheme glassCard];

    BOOL isSelected = (category == nil && self.selected == nil) ||
                      (category && [category isEqualToString:self.selected]);
    cell.accessoryType = isSelected ? UITableViewCellAccessoryCheckmark : UITableViewCellAccessoryNone;
    cell.tintColor = [MVTheme accent];
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    NSArray *entry = self.types[indexPath.row];
    NSString *category = entry.count > 3 ? entry[3] : nil;
    self.selected = category;
    [tableView reloadData];
    if (self.onSelect) self.onSelect(category);
    [self dismissViewControllerAnimated:YES completion:nil];
}

@end
