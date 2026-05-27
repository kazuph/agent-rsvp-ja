#import <Cocoa/Cocoa.h>
#import <NaturalLanguage/NaturalLanguage.h>
#import <unistd.h>

static const NSInteger MIN_WPM = 100;
static const NSInteger MAX_WPM = 1200;
static const NSInteger WPM_STEP = 25;
static const NSInteger MIN_LINES = 1;
static const NSInteger MAX_LINES = 12;
static const CGFloat DEFAULT_FONT_SIZE = 42.0;
static const CGFloat MIN_FONT_SIZE = 22.0;
static const CGFloat MAX_FONT_SIZE = 88.0;
static const CGFloat FONT_SIZE_STEP = 4.0;

static NSInteger visibleCharCount(NSString *s);

@interface RSVPState : NSObject
@property(nonatomic, strong) NSMutableArray<NSString *> *chunks;
@property(nonatomic, copy) NSString *currentPath;
@property(nonatomic) NSInteger index;
@property(nonatomic) NSInteger wpm;
@property(nonatomic) NSInteger visibleLines;
@property(nonatomic) BOOL paused;
@property(nonatomic) BOOL showHud;
@property(nonatomic) BOOL contextMode;
@property(nonatomic) CGFloat fontSize;
@property(nonatomic) NSTimeInterval nextAdvance;
@property(nonatomic, strong) NSTimer *timer;
@end

@implementation RSVPState
@end

static BOOL containsJapanese(NSString *s) {
    for (NSUInteger i = 0; i < s.length; i++) {
        unichar c = [s characterAtIndex:i];
        if ((c >= 0x3040 && c <= 0x30ff) || (c >= 0x3400 && c <= 0x9fff)) return YES;
    }
    return NO;
}

static NSUInteger alnumCount(NSString *s) {
    NSCharacterSet *set = [NSCharacterSet alphanumericCharacterSet];
    NSUInteger count = 0;
    for (NSUInteger i = 0; i < s.length; i++) {
        if ([set characterIsMember:[s characterAtIndex:i]]) count++;
    }
    return count;
}

static BOOL isPunctuation(NSString *s) {
    if (s.length == 0) return NO;
    NSCharacterSet *punct = [NSCharacterSet characterSetWithCharactersInString:@"、。，．,.!?！？;；:：)）]］」』"];
    for (NSUInteger i = 0; i < s.length; i++) {
        if (![punct characterIsMember:[s characterAtIndex:i]]) return NO;
    }
    return YES;
}

static void absorbShortJapaneseChunks(NSMutableArray<NSString *> *chunks) {
    NSInteger i = 0;
    while (i < (NSInteger)chunks.count) {
        NSString *current = chunks[(NSUInteger)i];
        if (!containsJapanese(current) || alnumCount(current) > 1) {
            i++;
            continue;
        }

        if (i + 1 < (NSInteger)chunks.count && containsJapanese(chunks[(NSUInteger)i + 1])) {
            chunks[(NSUInteger)i] = [current stringByAppendingString:chunks[(NSUInteger)i + 1]];
            [chunks removeObjectAtIndex:(NSUInteger)i + 1];
            continue;
        }

        if (i > 0 && containsJapanese(chunks[(NSUInteger)i - 1])) {
            chunks[(NSUInteger)i - 1] = [chunks[(NSUInteger)i - 1] stringByAppendingString:current];
            [chunks removeObjectAtIndex:(NSUInteger)i];
            continue;
        }
        i++;
    }
}

static void absorbTinyChunks(NSMutableArray<NSString *> *chunks) {
    NSInteger i = 0;
    while (i < (NSInteger)chunks.count) {
        NSString *current = chunks[(NSUInteger)i];
        if (visibleCharCount(current) > 1) {
            i++;
            continue;
        }

        if (i + 1 < (NSInteger)chunks.count) {
            chunks[(NSUInteger)i] = [current stringByAppendingString:chunks[(NSUInteger)i + 1]];
            [chunks removeObjectAtIndex:(NSUInteger)i + 1];
            continue;
        }

        if (i > 0) {
            chunks[(NSUInteger)i - 1] = [chunks[(NSUInteger)i - 1] stringByAppendingString:current];
            [chunks removeObjectAtIndex:(NSUInteger)i];
            continue;
        }
        i++;
    }
}

static NSString *stripFrontMatter(NSString *text) {
    if (![text hasPrefix:@"---"]) return text ?: @"";
    NSRange firstLine = [text rangeOfString:@"\n"];
    if (firstLine.location == NSNotFound) return text;
    NSRange end = [text rangeOfString:@"\n---" options:0 range:NSMakeRange(firstLine.location + 1, text.length - firstLine.location - 1)];
    if (end.location == NSNotFound) return text;
    NSUInteger start = end.location + end.length;
    if (start < text.length && [text characterAtIndex:start] == '\r') start++;
    if (start < text.length && [text characterAtIndex:start] == '\n') start++;
    return [text substringFromIndex:start];
}

static NSString *stripMarkdown(NSString *text) {
    NSArray<NSArray<NSString *> *> *rules = @[
        @[ @"(?s)```.*?```", @" " ],
        @[ @"(?s)~~~.*?~~~", @" " ],
        @[ @"`([^`]*)`", @"$1" ],
        @[ @"!\\[[^\\]]*\\]\\([^)]*\\)", @" " ],
        @[ @"\\[([^\\]]+)\\]\\([^)]*\\)", @"$1" ],
        @[ @"<[^>\\n]+>", @" " ],
        @[ @"[*_]{1,3}", @"" ],
        @[ @"(?m)^\\s{0,3}#{1,6}\\s+", @"" ],
        @[ @"(?m)^\\s{0,3}>\\s?", @"" ],
        @[ @"(?m)^\\s*[-*+]\\s+", @"" ],
        @[ @"(?m)^\\s*\\d+\\.\\s+", @"" ],
        @[ @"\\|", @" " ],
    ];

    NSMutableString *out = [stripFrontMatter(text) mutableCopy];
    for (NSArray<NSString *> *rule in rules) {
        NSRegularExpression *re = [NSRegularExpression regularExpressionWithPattern:rule[0] options:0 error:nil];
        [re replaceMatchesInString:out options:0 range:NSMakeRange(0, out.length) withTemplate:rule[1]];
    }
    return [out stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
}

static NSString *decodeHtmlEntities(NSString *text) {
    NSMutableString *out = [text mutableCopy];
    NSDictionary<NSString *, NSString *> *entities = @{
        @"&nbsp;": @" ",
        @"&amp;": @"&",
        @"&lt;": @"<",
        @"&gt;": @">",
        @"&quot;": @"\"",
        @"&#39;": @"'",
        @"&apos;": @"'"
    };
    for (NSString *key in entities) {
        [out replaceOccurrencesOfString:key withString:entities[key] options:NSCaseInsensitiveSearch range:NSMakeRange(0, out.length)];
    }
    return out;
}

static NSString *firstHtmlCapture(NSString *html, NSArray<NSString *> *patterns) {
    for (NSString *pattern in patterns) {
        NSRegularExpression *re = [NSRegularExpression regularExpressionWithPattern:pattern options:NSRegularExpressionCaseInsensitive error:nil];
        NSTextCheckingResult *match = [re firstMatchInString:html options:0 range:NSMakeRange(0, html.length)];
        if (match && match.numberOfRanges > 1) {
            return [html substringWithRange:[match rangeAtIndex:1]];
        }
    }
    return html;
}

static NSString *stripHtml(NSString *html) {
    NSMutableString *out = [firstHtmlCapture(html, @[
        @"(?s)<article\\b[^>]*>(.*?)</article>",
        @"(?s)<main\\b[^>]*>(.*?)</main>",
        @"(?s)<body\\b[^>]*>(.*?)</body>"
    ]) mutableCopy];

    NSArray<NSArray<NSString *> *> *rules = @[
        @[ @"(?s)<(script|style|noscript|iframe|svg)\\b[^>]*>.*?</\\1>", @" " ],
        @[ @"(?s)<pre\\b[^>]*>.*?</pre>", @" " ],
        @[ @"(?i)<br\\s*/?>", @"\n" ],
        @[ @"(?i)</(p|div|section|article|main|h[1-6]|li|tr)>", @"\n" ],
        @[ @"(?s)<[^>]+>", @" " ],
        @[ @"[ \\t\\r\\f\\v]+", @" " ],
        @[ @"\\n\\s*\\n+", @"\n" ],
    ];
    for (NSArray<NSString *> *rule in rules) {
        NSRegularExpression *re = [NSRegularExpression regularExpressionWithPattern:rule[0] options:0 error:nil];
        [re replaceMatchesInString:out options:0 range:NSMakeRange(0, out.length) withTemplate:rule[1]];
    }
    return [decodeHtmlEntities(out) stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
}

static BOOL isAsciiWordChar(unichar c) {
    return (c >= 'a' && c <= 'z') ||
           (c >= 'A' && c <= 'Z') ||
           (c >= '0' && c <= '9') ||
           c == '_' || c == '-' || c == '.' || c == '+' || c == '#' || c == '/' || c == '~';
}

static BOOL isJapaneseChar(unichar c) {
    return (c >= 0x3040 && c <= 0x30ff) || (c >= 0x3400 && c <= 0x9fff);
}

static BOOL hasAsciiWord(NSString *s) {
    for (NSUInteger i = 0; i < s.length; i++) {
        if (isAsciiWordChar([s characterAtIndex:i])) return YES;
    }
    return NO;
}

static NSInteger visibleCharCount(NSString *s) {
    NSInteger count = 0;
    NSCharacterSet *skip = [NSCharacterSet whitespaceAndNewlineCharacterSet];
    for (NSUInteger i = 0; i < s.length; i++) {
        if (![skip characterIsMember:[s characterAtIndex:i]]) count++;
    }
    return count;
}

static NSInteger displayWeight(NSString *s) {
    if (s.length == 0) return 0;
    if (!containsJapanese(s) && hasAsciiWord(s)) {
        return MIN(4, MAX(2, ((NSInteger)s.length + 3) / 4));
    }
    return (NSInteger)s.length;
}

static NSInteger chunkWeight(NSString *s) {
    NSInteger weight = 0;
    NSArray<NSString *> *parts = [s componentsSeparatedByCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
    for (NSString *part in parts) weight += displayWeight(part);
    return weight;
}

static BOOL needsSpaceBetween(NSString *left, NSString *right) {
    if (left.length == 0 || right.length == 0) return NO;
    if (isPunctuation(right)) return NO;
    NSUInteger lastIndex = left.length - 1;
    while (lastIndex > 0 && [[NSCharacterSet whitespaceCharacterSet] characterIsMember:[left characterAtIndex:lastIndex]]) {
        lastIndex--;
    }
    unichar last = [left characterAtIndex:lastIndex];
    unichar first = [right characterAtIndex:0];
    if (isPunctuation([NSString stringWithCharacters:&last length:1])) return NO;
    return isAsciiWordChar(last) || isAsciiWordChar(first);
}

static NSString *appendDisplayAtom(NSString *chunk, NSString *atom) {
    if (chunk.length == 0) return atom;
    return [chunk stringByAppendingFormat:@"%@%@", needsSpaceBetween(chunk, atom) ? @" " : @"", atom];
}

static BOOL endsWithAny(NSString *s, NSArray<NSString *> *suffixes) {
    for (NSString *suffix in suffixes) {
        if ([s hasSuffix:suffix]) return YES;
    }
    return NO;
}

static BOOL isNaturalBreakChunk(NSString *chunk) {
    if (chunk.length == 0) return NO;
    static NSArray<NSString *> *suffixes;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        suffixes = @[
            @"は", @"が", @"を", @"に", @"で", @"と", @"も", @"へ", @"から", @"まで", @"より",
            @"なら", @"だけ", @"とは", @"には", @"では", @"でも", @"にも", @"からは",
            @"です", @"ます", @"でした", @"ました", @"ません", @"だった", @"なのに", @"ので", @"のが",
            @"して", @"した", @"している", @"していた", @"ている", @"ていた", @"ていく", @"てくる",
            @"たい", @"たかった", @"られる", @"れる", @"せず", @"つつ", @"ながら", @"として", @"という"
        ];
    });
    return endsWithAny(chunk, suffixes);
}

static BOOL isBadJapaneseTail(NSString *chunk) {
    static NSArray<NSString *> *tails;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        tails = @[
            @"いま", @"できな", @"しな", @"ならな", @"わからな", @"動かな", @"入れな",
            @"いまし", @"まし",
            @"なが", @"コア", @"コア処",
            @"書いていま", @"していま", @"されていま", @"なっていま", @"持っていま",
            @"ジャンプできな"
        ];
    });
    return endsWithAny(chunk, tails);
}

static BOOL isPoorLeadingAtom(NSString *atom) {
    static NSArray<NSString *> *atoms;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        atoms = @[ @"い", @"う", @"く", @"し", @"す", @"た", @"て", @"で", @"な", @"に", @"の", @"は", @"ま", @"も", @"ら", @"り", @"る", @"れ", @"を", @"が", @"か" ];
    });
    return [atoms containsObject:atom];
}

static BOOL shouldDelayBreakBeforeNext(NSString *chunk, NSString *atom, NSString *text, NSUInteger nextIndex) {
    if (nextIndex >= text.length) return NO;
    unichar next = [text characterAtIndex:nextIndex];
    NSString *nextString = [NSString stringWithCharacters:&next length:1];
    if (isPunctuation(nextString)) return YES;
    if ([atom isEqualToString:@"で"] && (next == 0x3059 || next == 0x3057 || next == 0x306E || next == 0x306F || next == 0x304D || next == 0x3082 || next == 0x3042)) return YES; // です / でした / での / では / でき / でも / である
    if ([atom isEqualToString:@"は"] && next == 0x306A) return YES; // はなく
    if ([atom isEqualToString:@"も"] && next == 0x306E) return YES; // もの
    if ([chunk hasSuffix:@"だけ"] && next == 0x3067) return YES; // だけで
    if ([chunk hasSuffix:@"こと"] && (next == 0x3092 || next == 0x3082)) return YES; // ことを / ことも
    if ([chunk hasSuffix:@"もの"] && next == 0x306F) return YES; // ものは
    if ([chunk hasSuffix:@"と"] && next == 0x3093) return YES; // とんと
    if ([chunk hasSuffix:@"あと"] && next == 0x3067) return YES; // あとで
    if ([chunk hasSuffix:@"なが"] && next == 0x3089) return YES; // ながら
    if ([chunk hasSuffix:@"コア"] && next == 0x51E6) return YES; // コア処理
    if ([chunk hasSuffix:@"コア処"] && next == 0x7406) return YES; // コア処理
    if (([chunk hasSuffix:@"です"] || [chunk hasSuffix:@"ます"]) && next == 0x304C) return YES; // ですが / ますが
    if ([chunk hasSuffix:@"から"] && next == 0x306F) return YES; // からは
    if ([chunk hasSuffix:@"した"] && next == 0x306E) return YES; // したの
    if (([chunk hasSuffix:@"ている"] || [chunk hasSuffix:@"いる"]) && (next == 0x3068 || next == 0x306E || next == 0x3082 || next == 0x3089)) return YES; // ていると / ているの / ているも / ているら
    if (([chunk hasSuffix:@"ていた"] || [chunk hasSuffix:@"いた"] || [chunk hasSuffix:@"した"] || [chunk hasSuffix:@"った"] || [chunk hasSuffix:@"えた"] || [chunk hasSuffix:@"れた"]) && next == 0x3089) return YES; // ていたら / したら / ったら
    if ([chunk hasSuffix:@"して"] && (next == 0x3044 || next == 0x304A)) return YES; // している / しておく
    if ([chunk hasSuffix:@"て"] && (next == 0x3044 || next == 0x304A || next == 0x304F)) return YES; // ている / ておく / てくる
    if (isBadJapaneseTail(chunk)) return YES;
    return NO;
}

static void flushChunk(NSMutableArray<NSString *> *chunks, NSMutableString *chunk) {
    NSString *trimmed = [chunk stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (trimmed.length > 0) [chunks addObject:trimmed];
    [chunk setString:@""];
}

static NSMutableArray<NSString *> *tokenize(NSString *text) {
    NSMutableArray<NSString *> *chunks = [NSMutableArray array];
    NSMutableString *chunk = [NSMutableString string];
    NSCharacterSet *newlines = [NSCharacterSet newlineCharacterSet];
    NSCharacterSet *whitespace = [NSCharacterSet whitespaceAndNewlineCharacterSet];

    for (NSUInteger i = 0; i < text.length;) {
        unichar c = [text characterAtIndex:i];
        if ([newlines characterIsMember:c]) {
            flushChunk(chunks, chunk);
            i++;
            continue;
        }
        if ([whitespace characterIsMember:c]) {
            i++;
            continue;
        }

        NSString *atom;
        if (isAsciiWordChar(c)) {
            NSUInteger start = i;
            while (i < text.length && isAsciiWordChar([text characterAtIndex:i])) i++;
            atom = [text substringWithRange:NSMakeRange(start, i - start)];
        } else {
            atom = [text substringWithRange:NSMakeRange(i, 1)];
            i++;
        }

        if (isPunctuation(atom) && chunk.length == 0) {
            if (chunks.count > 0) {
                chunks[chunks.count - 1] = [chunks.lastObject stringByAppendingString:atom];
            }
            continue;
        }

        NSString *candidate = appendDisplayAtom(chunk, atom);
        BOOL hardBreak = isPunctuation(atom);
        NSInteger weight = chunkWeight(candidate);

        BOOL tooWide = visibleCharCount(candidate) > 18;
        if (chunk.length > 0 && !hardBreak && (weight > 14 || tooWide) && !isPoorLeadingAtom(atom) && !shouldDelayBreakBeforeNext(chunk, atom, text, i)) {
            flushChunk(chunks, chunk);
            candidate = atom;
            weight = chunkWeight(candidate);
        }

        [chunk setString:candidate];
        BOOL softBreak = weight >= 5 && isNaturalBreakChunk(chunk) && !shouldDelayBreakBeforeNext(chunk, atom, text, i);
        if (hardBreak || softBreak || ((weight >= 16 || visibleCharCount(chunk) >= 20) && !shouldDelayBreakBeforeNext(chunk, atom, text, i))) {
            flushChunk(chunks, chunk);
        }
    }
    flushChunk(chunks, chunk);
    return chunks;
}

static NSString *readableTextFromText(NSString *text, NSString *path) {
    NSString *source = text ?: @"";
    NSString *lowerPath = path.lowercaseString ?: @"";
    BOOL htmlLike = [lowerPath hasSuffix:@".html"] || [lowerPath hasSuffix:@".htm"] || [source rangeOfString:@"<html" options:NSCaseInsensitiveSearch].location != NSNotFound || [source rangeOfString:@"<article" options:NSCaseInsensitiveSearch].location != NSNotFound;
    return htmlLike ? stripHtml(stripFrontMatter(source)) : stripMarkdown(source);
}

static NSMutableArray<NSString *> *chunksFromText(NSString *text, NSString *path) {
    NSString *clean = readableTextFromText(text, path);
    if (clean.length == 0) return [NSMutableArray array];
    NSMutableArray<NSString *> *chunks = tokenize(clean);
    absorbShortJapaneseChunks(chunks);
    absorbTinyChunks(chunks);
    return chunks;
}

static NSString *resolveInputPath(NSString *path) {
    if (path.length == 0) return nil;
    NSFileManager *fm = NSFileManager.defaultManager;
    if ([fm fileExistsAtPath:path]) return path;

    NSArray<NSString *> *candidates = @[
        [@"_posts" stringByAppendingPathComponent:path],
        [@"_posts/zenn" stringByAppendingPathComponent:path],
        [[fm.currentDirectoryPath stringByAppendingPathComponent:@"_posts"] stringByAppendingPathComponent:path],
        [[fm.currentDirectoryPath stringByAppendingPathComponent:@"_posts/zenn"] stringByAppendingPathComponent:path],
    ];
    for (NSString *candidate in candidates) {
        if ([fm fileExistsAtPath:candidate]) return candidate;
    }
    return path;
}

static CGFloat textWidth(NSString *s, NSDictionary<NSAttributedStringKey, id> *attrs) {
    return ceil([s sizeWithAttributes:attrs].width);
}

static NSFont *safeFont(NSFont *font, CGFloat size) {
    if (font) return font;
    return [NSFont systemFontOfSize:MAX(1.0, size > 0 ? size : DEFAULT_FONT_SIZE)];
}

static NSDictionary<NSAttributedStringKey, id> *textAttrs(NSFont *font, NSColor *color, CGFloat fallbackSize) {
    return @{
        NSFontAttributeName: safeFont(font, fallbackSize),
        NSForegroundColorAttributeName: color ?: NSColor.whiteColor
    };
}

static CGFloat clampFontSize(CGFloat size) {
    return MIN(MAX_FONT_SIZE, MAX(MIN_FONT_SIZE, size));
}

static NSString *contextJoin(NSString *line, NSString *token) {
    if (line.length == 0) return token;
    BOOL tight = containsJapanese(line) || containsJapanese(token) || isPunctuation(token);
    return [line stringByAppendingFormat:@"%@%@", tight ? @"" : @" ", token];
}

static NSArray<NSString *> *wrappedContextLines(NSArray<NSString *> *chunks, NSInteger start, NSInteger end, CGFloat maxWidth, NSDictionary<NSAttributedStringKey, id> *attrs) {
    NSMutableArray<NSString *> *lines = [NSMutableArray array];
    NSInteger count = (NSInteger)chunks.count;
    start = MAX(0, MIN(start, count));
    end = MAX(start, MIN(end, count));

    NSString *line = @"";
    for (NSInteger i = start; i < end; i++) {
        NSString *token = chunks[(NSUInteger)i];
        NSString *candidate = contextJoin(line, token);
        if (line.length > 0 && textWidth(candidate, attrs) > maxWidth) {
            [lines addObject:line];
            line = token;
        } else {
            line = candidate;
        }
    }
    if (line.length > 0) [lines addObject:line];
    return lines;
}

static NSInteger orpIndex(NSString *word) {
    NSUInteger n = word.length;
    if (n <= 1) return 0;
    if (n <= 5) return 1;
    if (n <= 9) return 2;
    if (n <= 13) return 3;
    return 4;
}

static NSInteger centerRightVisibleIndex(NSString *text) {
    if (text.length == 0) return 0;
    NSCharacterSet *skip = [NSCharacterSet whitespaceAndNewlineCharacterSet];
    NSInteger visible = visibleCharCount(text);
    if (visible <= 0) return 0;
    NSInteger target = visible / 2; // odd: center, even: center-right
    NSInteger seen = 0;
    for (NSUInteger i = 0; i < text.length; i++) {
        if ([skip characterIsMember:[text characterAtIndex:i]]) continue;
        if (seen == target) return (NSInteger)i;
        seen++;
    }
    return MAX(0, (NSInteger)text.length - 1);
}

static NSInteger focalIndexForChunk(NSString *text) {
    return centerRightVisibleIndex(text);
}

static NSString *focalPreview(NSString *text) {
    if (text.length == 0) return @"";
    NSInteger idx = MIN(focalIndexForChunk(text), MAX((NSInteger)text.length - 1, 0));
    NSString *before = [text substringToIndex:(NSUInteger)idx];
    NSString *focal = [text substringWithRange:NSMakeRange((NSUInteger)idx, 1)];
    NSString *after = [text substringFromIndex:(NSUInteger)idx + 1];
    return [NSString stringWithFormat:@"%@[%@]%@", before, focal, after];
}

@interface RSVPView : NSView
@property(nonatomic, strong) RSVPState *state;
@end

@interface AppDelegate : NSObject <NSApplicationDelegate>
@property(nonatomic, strong) NSWindow *window;
@property(nonatomic, strong) RSVPState *state;
@property(nonatomic, strong) RSVPView *view;
@property(nonatomic) BOOL openPanelOnLaunch;
- (void)openDocument:(id)sender;
- (void)increaseFontSize:(id)sender;
- (void)decreaseFontSize:(id)sender;
- (void)resetFontSize:(id)sender;
@end

@implementation RSVPView

- (BOOL)acceptsFirstResponder { return YES; }

- (void)viewDidMoveToWindow {
    [self.window makeFirstResponder:self];
}

- (BOOL)performKeyEquivalent:(NSEvent *)event {
    if ((event.modifierFlags & NSEventModifierFlagCommand) == 0) {
        return [super performKeyEquivalent:event];
    }

    NSString *key = event.charactersIgnoringModifiers.lowercaseString ?: @"";
    NSString *chars = event.characters ?: @"";
    if ([key isEqualToString:@"-"] || [chars isEqualToString:@"-"]) {
        self.state.fontSize = clampFontSize(self.state.fontSize - FONT_SIZE_STEP);
    } else if ([key isEqualToString:@"="] || [chars isEqualToString:@"+"]) {
        self.state.fontSize = clampFontSize(self.state.fontSize + FONT_SIZE_STEP);
    } else if ([key isEqualToString:@"0"]) {
        self.state.fontSize = DEFAULT_FONT_SIZE;
    } else {
        return [super performKeyEquivalent:event];
    }

    [self setNeedsDisplay:YES];
    return YES;
}

- (void)keyDown:(NSEvent *)event {
    NSString *key = event.charactersIgnoringModifiers.lowercaseString;
    BOOL commandDown = (event.modifierFlags & NSEventModifierFlagCommand) != 0;
    if (commandDown && ([key isEqualToString:@"-"] || [key isEqualToString:@"_"])) {
        self.state.fontSize = clampFontSize(self.state.fontSize - FONT_SIZE_STEP);
    } else if (commandDown && ([key isEqualToString:@"="] || [key isEqualToString:@"+"])) {
        self.state.fontSize = clampFontSize(self.state.fontSize + FONT_SIZE_STEP);
    } else if (commandDown && [key isEqualToString:@"0"]) {
        self.state.fontSize = DEFAULT_FONT_SIZE;
    } else if ([key isEqualToString:@"q"] || event.keyCode == 53) {
        [NSApp terminate:nil];
    } else if ([key isEqualToString:@" "]) {
        self.state.paused = !self.state.paused;
        if (self.state.index >= (NSInteger)self.state.chunks.count) {
            self.state.index = 0;
            self.state.paused = NO;
        }
    } else if ([key isEqualToString:@"r"]) {
        self.state.index = 0;
        self.state.paused = NO;
    } else if ([key isEqualToString:@"o"]) {
        [(AppDelegate *)NSApp.delegate openDocument:nil];
    } else if ([key isEqualToString:@"f"]) {
        [self.window toggleFullScreen:nil];
    } else if ([key isEqualToString:@"?"]) {
        self.state.showHud = !self.state.showHud;
    } else if ([key isEqualToString:@"m"] || event.keyCode == 48) {
        self.state.contextMode = !self.state.contextMode;
    } else if ([key isEqualToString:@"h"] || event.keyCode == 123) {
        self.state.wpm = MAX(MIN_WPM, self.state.wpm - WPM_STEP);
    } else if ([key isEqualToString:@"l"] || event.keyCode == 124) {
        self.state.wpm = MIN(MAX_WPM, self.state.wpm + WPM_STEP);
    } else if ([key isEqualToString:@"j"]) {
        self.state.visibleLines = MAX(MIN_LINES, self.state.visibleLines - 1);
    } else if ([key isEqualToString:@"k"]) {
        self.state.visibleLines = MIN(MAX_LINES, self.state.visibleLines + 1);
    }
    [self setNeedsDisplay:YES];
}

- (void)drawRect:(NSRect)dirtyRect {
    [[NSColor colorWithCalibratedWhite:0.045 alpha:1.0] setFill];
    NSRectFill(self.bounds);

    CGFloat wordSize = clampFontSize(self.state.fontSize > 0 ? self.state.fontSize : DEFAULT_FONT_SIZE);
    NSFont *wordFont = [NSFont monospacedSystemFontOfSize:wordSize weight:NSFontWeightSemibold];
    NSDictionary *baseAttrs = textAttrs(wordFont, NSColor.whiteColor, wordSize);
    NSDictionary *redAttrs = textAttrs(wordFont, [NSColor colorWithCalibratedRed:1.0 green:0.28 blue:0.28 alpha:1.0], wordSize);
    NSFont *hudFont = [NSFont monospacedSystemFontOfSize:13 weight:NSFontWeightRegular];
    NSDictionary *hudAttrs = textAttrs(hudFont, [NSColor colorWithCalibratedWhite:0.68 alpha:1.0], 13.0);
    NSFont *contextFont = [NSFont systemFontOfSize:MAX(12.0, wordSize * 0.38) weight:NSFontWeightRegular];
    NSDictionary *contextAttrs = textAttrs(contextFont, [NSColor colorWithCalibratedWhite:0.48 alpha:1.0], MAX(12.0, wordSize * 0.38));

    if (self.state.chunks.count == 0) {
        NSString *message = @"Open a Markdown or text file";
        NSString *hint = @"Press O or Command-O";
        NSSize messageSize = [message sizeWithAttributes:baseAttrs];
        NSSize hintSize = [hint sizeWithAttributes:hudAttrs];
        [message drawAtPoint:NSMakePoint(NSMidX(self.bounds) - messageSize.width / 2.0, NSMidY(self.bounds) + 8) withAttributes:baseAttrs];
        [hint drawAtPoint:NSMakePoint(NSMidX(self.bounds) - hintSize.width / 2.0, NSMidY(self.bounds) - 28) withAttributes:hudAttrs];
        return;
    }

    NSInteger lineCount = MIN(self.state.visibleLines, (NSInteger)self.state.chunks.count - self.state.index);
    CGFloat rowHeight = MAX(38.0, wordSize * 1.34);
    CGFloat midY = NSMidY(self.bounds);
    CGFloat firstY = midY + ((CGFloat)(lineCount - 1) * rowHeight / 2.0);
    CGFloat focalX = NSMidX(self.bounds);
    CGFloat topGuideY = firstY + wordSize + 2.0;
    CGFloat bottomGuideY = firstY - ((CGFloat)(lineCount - 1) * rowHeight) - 18;

    if (self.state.contextMode) {
        CGFloat marginX = 36.0;
        CGFloat maxWidth = MAX(160.0, NSWidth(self.bounds) - marginX * 2.0);
        CGFloat contextRow = MAX(18.0, contextFont.pointSize * 1.35);
        NSInteger visibleContextLines = MAX(1, MIN(6, (NSInteger)((NSHeight(self.bounds) - 180.0) / (contextRow * 2.0))));

        NSArray<NSString *> *previous = wrappedContextLines(self.state.chunks, self.state.index - 96, self.state.index, maxWidth, contextAttrs);
        NSUInteger previousCount = MIN((NSUInteger)visibleContextLines, previous.count);
        if (previousCount > 0) {
            NSArray<NSString *> *tail = [previous subarrayWithRange:NSMakeRange(previous.count - previousCount, previousCount)];
            CGFloat y = MIN(NSMaxY(self.bounds) - 48.0, topGuideY + 24.0 + (CGFloat)(tail.count - 1) * contextRow);
            for (NSString *line in tail) {
                [line drawAtPoint:NSMakePoint(marginX, y) withAttributes:contextAttrs];
                y -= contextRow;
            }
        }

        NSArray<NSString *> *next = wrappedContextLines(self.state.chunks,
                                                        self.state.index + lineCount,
                                                        self.state.index + lineCount + 120,
                                                        maxWidth,
                                                        contextAttrs);
        NSUInteger nextCount = MIN((NSUInteger)visibleContextLines, next.count);
        for (NSUInteger i = 0; i < nextCount; i++) {
            CGFloat y = bottomGuideY - 34.0 - (CGFloat)i * contextRow;
            if (y < 44.0) break;
            [next[i] drawAtPoint:NSMakePoint(marginX, y) withAttributes:contextAttrs];
        }
    }

    [[NSColor colorWithCalibratedWhite:0.35 alpha:1.0] setStroke];
    NSBezierPath *top = [NSBezierPath bezierPath];
    [top moveToPoint:NSMakePoint(focalX - 220, topGuideY)];
    [top lineToPoint:NSMakePoint(focalX + 220, topGuideY)];
    [top stroke];
    NSBezierPath *bottom = [NSBezierPath bezierPath];
    [bottom moveToPoint:NSMakePoint(focalX - 220, bottomGuideY)];
    [bottom lineToPoint:NSMakePoint(focalX + 220, bottomGuideY)];
    [bottom stroke];

    for (NSInteger i = 0; i < lineCount; i++) {
        NSString *word = self.state.chunks[(NSUInteger)(self.state.index + i)];
        NSInteger idx = MIN(focalIndexForChunk(word), MAX((NSInteger)word.length - 1, 0));
        NSString *before = [word substringToIndex:(NSUInteger)idx];
        NSString *focal = [word substringWithRange:NSMakeRange((NSUInteger)idx, 1)];
        NSString *after = [word substringFromIndex:(NSUInteger)idx + 1];

        CGFloat lineFontSize = wordSize;
        CGFloat wordMargin = 28.0;
        CGFloat maxWordWidth = MAX(120.0, NSWidth(self.bounds) - wordMargin * 2.0);
        NSDictionary *lineBaseAttrs = baseAttrs;
        NSDictionary *lineRedAttrs = redAttrs;
        CGFloat beforeW = textWidth(before, lineBaseAttrs);
        CGFloat focalW = textWidth(focal, lineRedAttrs);
        CGFloat afterW = textWidth(after, lineBaseAttrs);
        CGFloat totalW = beforeW + focalW + afterW;

        while (totalW > maxWordWidth && lineFontSize > 14.0) {
            lineFontSize = MAX(14.0, lineFontSize - 2.0);
            NSFont *lineFont = [NSFont monospacedSystemFontOfSize:lineFontSize weight:NSFontWeightSemibold];
            lineBaseAttrs = textAttrs(lineFont, NSColor.whiteColor, lineFontSize);
            lineRedAttrs = textAttrs(lineFont, [NSColor colorWithCalibratedRed:1.0 green:0.28 blue:0.28 alpha:1.0], lineFontSize);
            beforeW = textWidth(before, lineBaseAttrs);
            focalW = textWidth(focal, lineRedAttrs);
            afterW = textWidth(after, lineBaseAttrs);
            totalW = beforeW + focalW + afterW;
        }

        CGFloat x = focalX - beforeW - focalW / 2.0;
        CGFloat minX = wordMargin;
        CGFloat maxX = NSMaxX(self.bounds) - wordMargin - totalW;
        if (x < minX) x = minX;
        if (x > maxX) x = maxX;
        if (maxX < minX) x = minX;

        CGFloat y = firstY - (CGFloat)i * rowHeight;
        [before drawAtPoint:NSMakePoint(x, y) withAttributes:lineBaseAttrs];
        [focal drawAtPoint:NSMakePoint(x + beforeW, y) withAttributes:lineRedAttrs];
        [after drawAtPoint:NSMakePoint(x + beforeW + focalW, y) withAttributes:lineBaseAttrs];
    }

    if (self.state.showHud) {
        NSInteger pct = ((self.state.index + 1) * 100) / MAX((NSInteger)self.state.chunks.count, 1);
        NSString *hud = [NSString stringWithFormat:@"%ld wpm  ·  lines:%ld  ·  font:%ld  ·  %@  ·  %@  ·  %ld/%lu (%ld%%)     o open   f full   m mode   ⌘-/⌘+ font   h/l speed   j/k lines   space pause   r restart   q quit",
                         (long)self.state.wpm,
                         (long)self.state.visibleLines,
                         (long)(wordSize + 0.5),
                         self.state.contextMode ? @"context" : @"minimal",
                         self.state.paused ? @"paused" : @"playing",
                         (long)self.state.index + 1,
                         (unsigned long)self.state.chunks.count,
                         (long)pct];
        if (textWidth(hud, hudAttrs) > NSWidth(self.bounds) - 40.0) {
            hud = [NSString stringWithFormat:@"%ld wpm  ·  lines:%ld  ·  font:%ld  ·  %@  ·  %@  ·  %ld/%lu (%ld%%)",
                   (long)self.state.wpm,
                   (long)self.state.visibleLines,
                   (long)(wordSize + 0.5),
                   self.state.contextMode ? @"context" : @"minimal",
                   self.state.paused ? @"paused" : @"playing",
                   (long)self.state.index + 1,
                   (unsigned long)self.state.chunks.count,
                   (long)pct];
        }
        [hud drawAtPoint:NSMakePoint(20, 18) withAttributes:hudAttrs];
    }
}

@end

@implementation AppDelegate

- (void)installMainMenu {
    NSMenu *bar = [NSMenu new];
    NSMenuItem *appItem = [NSMenuItem new];
    NSMenu *appMenu = [NSMenu new];
    [appMenu addItemWithTitle:@"Quit agent-rsvp" action:@selector(terminate:) keyEquivalent:@"q"];
    appItem.submenu = appMenu;
    [bar addItem:appItem];

    NSMenuItem *fileItem = [NSMenuItem new];
    NSMenu *fileMenu = [[NSMenu alloc] initWithTitle:@"File"];
    NSMenuItem *openItem = [[NSMenuItem alloc] initWithTitle:@"Open..." action:@selector(openDocument:) keyEquivalent:@"o"];
    openItem.target = self;
    [fileMenu addItem:openItem];
    fileItem.submenu = fileMenu;
    [bar addItem:fileItem];

    NSMenuItem *viewItem = [NSMenuItem new];
    NSMenu *viewMenu = [[NSMenu alloc] initWithTitle:@"View"];
    NSMenuItem *largerItem = [[NSMenuItem alloc] initWithTitle:@"Make Text Bigger" action:@selector(increaseFontSize:) keyEquivalent:@"="];
    largerItem.target = self;
    [viewMenu addItem:largerItem];
    NSMenuItem *smallerItem = [[NSMenuItem alloc] initWithTitle:@"Make Text Smaller" action:@selector(decreaseFontSize:) keyEquivalent:@"-"];
    smallerItem.target = self;
    [viewMenu addItem:smallerItem];
    NSMenuItem *resetItem = [[NSMenuItem alloc] initWithTitle:@"Reset Text Size" action:@selector(resetFontSize:) keyEquivalent:@"0"];
    resetItem.target = self;
    [viewMenu addItem:resetItem];
    viewItem.submenu = viewMenu;
    [bar addItem:viewItem];
    NSApp.mainMenu = bar;
}

- (void)increaseFontSize:(id)sender {
    (void)sender;
    self.state.fontSize = clampFontSize(self.state.fontSize + FONT_SIZE_STEP);
    [self.view setNeedsDisplay:YES];
}

- (void)decreaseFontSize:(id)sender {
    (void)sender;
    self.state.fontSize = clampFontSize(self.state.fontSize - FONT_SIZE_STEP);
    [self.view setNeedsDisplay:YES];
}

- (void)resetFontSize:(id)sender {
    (void)sender;
    self.state.fontSize = DEFAULT_FONT_SIZE;
    [self.view setNeedsDisplay:YES];
}

- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    (void)notification;
    [self installMainMenu];

    NSRect frame = NSMakeRect(0, 0, 940, 560);
    self.window = [[NSWindow alloc] initWithContentRect:frame
                                              styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskMiniaturizable | NSWindowStyleMaskResizable
                                                backing:NSBackingStoreBuffered
                                                  defer:NO];
    self.window.title = @"agent-rsvp";
    [self.window center];

    self.view = [[RSVPView alloc] initWithFrame:frame];
    self.view.state = self.state;
    self.window.contentView = self.view;
    [self.window makeKeyAndOrderFront:nil];
    [NSApp activateIgnoringOtherApps:YES];

    if (self.openPanelOnLaunch) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self openDocument:nil];
        });
    }

    self.state.timer = [NSTimer scheduledTimerWithTimeInterval:0.03 repeats:YES block:^(NSTimer *timer) {
        (void)timer;
        if (self.state.paused || self.state.index >= (NSInteger)self.state.chunks.count) {
            return;
        }
        NSTimeInterval now = NSDate.timeIntervalSinceReferenceDate;
        if (now >= self.state.nextAdvance) {
            NSInteger step = MAX(MIN_LINES, self.state.visibleLines);
            NSInteger nextIndex = self.state.index + step;
            if (nextIndex >= (NSInteger)self.state.chunks.count) {
                self.state.index = MAX(0, (NSInteger)self.state.chunks.count - MAX(MIN_LINES, self.state.visibleLines));
                self.state.paused = YES;
            } else {
                self.state.index = nextIndex;
            }
            double interval = 60.0 / (double)MAX(self.state.wpm, MIN_WPM);
            self.state.nextAdvance = now + MAX(interval, 0.025);
            [self.view setNeedsDisplay:YES];
        }
    }];
}

- (void)openDocument:(id)sender {
    (void)sender;
    NSOpenPanel *panel = [NSOpenPanel openPanel];
    panel.canChooseFiles = YES;
    panel.canChooseDirectories = NO;
    panel.allowsMultipleSelection = NO;
    panel.title = @"Open Article";
    panel.message = @"Choose a Markdown or text file to speed read.";

    [panel beginSheetModalForWindow:self.window completionHandler:^(NSModalResponse result) {
        if (result != NSModalResponseOK) return;
        NSURL *url = panel.URL;
        if (!url) return;

        NSError *error = nil;
        NSString *text = [NSString stringWithContentsOfURL:url encoding:NSUTF8StringEncoding error:&error];
        if (!text) {
            NSAlert *alert = [NSAlert new];
            alert.messageText = @"Could not open file";
            alert.informativeText = error.localizedDescription ?: @"The file could not be read as UTF-8 text.";
            [alert beginSheetModalForWindow:self.window completionHandler:nil];
            return;
        }

        NSMutableArray<NSString *> *chunks = chunksFromText(text, url.path);
        if (chunks.count == 0) {
            NSAlert *alert = [NSAlert new];
            alert.messageText = @"No readable text";
            alert.informativeText = @"The selected file did not contain readable text after Markdown cleanup.";
            [alert beginSheetModalForWindow:self.window completionHandler:nil];
            return;
        }

        self.state.chunks = chunks;
        self.state.currentPath = url.path;
        self.state.index = 0;
        self.state.nextAdvance = 0;
        self.state.paused = NO;
        self.window.title = [NSString stringWithFormat:@"agent-rsvp — %@", url.lastPathComponent ?: @"Untitled"];
        [self.view setNeedsDisplay:YES];
    }];
}

@end

static NSString *readAllStdin(void) {
    if (isatty(STDIN_FILENO)) return @"";
    NSMutableData *data = [NSMutableData data];
    uint8_t buf[8192];
    ssize_t n;
    while ((n = read(STDIN_FILENO, buf, sizeof(buf))) > 0) {
        [data appendBytes:buf length:(NSUInteger)n];
    }
    return [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] ?: @"";
}

int agent_rsvp_app_main(int argc, char **argv) {
    @autoreleasepool {
        NSInteger wpm = 600;
        NSString *file = nil;
        BOOL dumpText = NO;
        BOOL testMode = NO;
        BOOL testLayout = NO;
        for (int i = 1; i < argc; i++) {
            NSString *arg = [NSString stringWithUTF8String:argv[i]];
            if (([arg isEqualToString:@"-w"] || [arg isEqualToString:@"--wpm"]) && i + 1 < argc) {
                wpm = [[NSString stringWithUTF8String:argv[++i]] integerValue];
            } else if ([arg hasPrefix:@"--wpm="]) {
                wpm = [[arg substringFromIndex:6] integerValue];
            } else if ([arg hasPrefix:@"-w"] && arg.length > 2) {
                wpm = [[arg substringFromIndex:2] integerValue];
            } else if ([arg isEqualToString:@"--dump-text"]) {
                dumpText = YES;
            } else if ([arg isEqualToString:@"-t"] || [arg isEqualToString:@"--test"]) {
                testMode = YES;
            } else if ([arg isEqualToString:@"--test-layout"]) {
                testLayout = YES;
            } else if (![arg hasPrefix:@"-"]) {
                file = arg;
            }
        }
        wpm = MIN(MAX_WPM, MAX(MIN_WPM, wpm));

        NSString *text = nil;
        if (file) {
            file = resolveInputPath(file);
            text = [NSString stringWithContentsOfFile:file encoding:NSUTF8StringEncoding error:nil];
        } else {
            text = readAllStdin();
        }
        if (dumpText) {
            NSString *readable = readableTextFromText(text, file ?: @"");
            NSData *data = [readable dataUsingEncoding:NSUTF8StringEncoding];
            if (data) write(STDOUT_FILENO, data.bytes, data.length);
            return 0;
        }
        if (testMode || testLayout) {
            NSMutableArray<NSString *> *chunks = chunksFromText(text, file ?: @"");
            NSMutableString *out = [NSMutableString string];
            NSUInteger n = 0;
            for (NSString *chunk in chunks) {
                if (testLayout) {
                    n++;
                    [out appendFormat:@"%4lu  %@\n", (unsigned long)n, focalPreview(chunk)];
                } else {
                    [out appendString:chunk];
                    [out appendString:@"\n"];
                }
            }
            NSData *data = [out dataUsingEncoding:NSUTF8StringEncoding];
            if (data) write(STDOUT_FILENO, data.bytes, data.length);
            return 0;
        }

        RSVPState *state = [RSVPState new];
        state.chunks = chunksFromText(text, file ?: @"");
        state.currentPath = file ?: @"";
        state.index = 0;
        state.wpm = wpm;
        state.visibleLines = 1;
        state.paused = state.chunks.count == 0;
        state.showHud = YES;
        state.contextMode = NO;
        state.fontSize = DEFAULT_FONT_SIZE;
        state.nextAdvance = 0;

        NSApplication *app = NSApplication.sharedApplication;
        app.activationPolicy = NSApplicationActivationPolicyRegular;
        AppDelegate *delegate = [AppDelegate new];
        delegate.state = state;
        delegate.openPanelOnLaunch = state.chunks.count == 0;
        app.delegate = delegate;
        [app run];
    }
    return 0;
}
