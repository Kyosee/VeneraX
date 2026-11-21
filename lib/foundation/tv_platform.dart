/// Selects the television shell before the shared application initializes.
bool _television = false;

bool get isTvApp => _television;

void enableTvApp() => _television = true;
